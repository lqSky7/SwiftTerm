import Foundation

/// A pseudo-terminal and the process attached to it.
///
/// `@unchecked Sendable` is a written exception, not a shortcut: the only shared state is a file
/// descriptor, which is an `Int32` and is safe to read and write from any thread, and the child
/// pid, which is only ever passed to `kill` and `waitpid`.
final class PseudoTerminal: @unchecked Sendable {
    let masterFileDescriptor: Int32
    let processID: pid_t

    private let lock = NSLock()
    private var isClosed = false

    private init(masterFileDescriptor: Int32, processID: pid_t) {
        self.masterFileDescriptor = masterFileDescriptor
        self.processID = processID
    }

    /// Starts `executable` on a new pseudo-terminal with itself as the session leader.
    ///
    /// `forkpty` does `openpty` + `fork` + `setsid` + `TIOCSCTTY` + `dup2` in one call, and the
    /// `TIOCSCTTY` is the part that matters: without a controlling terminal a shell cannot put a
    /// job in the foreground, so `Ctrl-C`, `Ctrl-Z` and `fg` all do nothing.
    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        size: TerminalSize
    ) -> PseudoTerminal? {
        // Both arrays must outlive the fork, so they are built in the parent. The child only ever
        // calls async-signal-safe functions before `execve`, which is what makes `fork` legal here.
        let argv = CStringArray([executable] + arguments)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" })
        var windowSize = Self.windowSize(for: size)

        var master: Int32 = -1
        let child = forkpty(&master, nil, nil, &windowSize)

        if child == 0 {
            _ = workingDirectory.withCString { chdir($0) }
            execve(executable, argv.pointers, envp.pointers)
            _exit(127)                              // exec failed; there is nothing left to report to
        }
        guard child > 0, master >= 0 else {
            if master >= 0 { Darwin.close(master) }
            return nil
        }
        return PseudoTerminal(masterFileDescriptor: master, processID: child)
    }

    /// Tells the kernel the window changed size, which is what makes a full-screen program reflow.
    func resize(to size: TerminalSize) {
        var windowSize = Self.windowSize(for: size)
        _ = ioctl(masterFileDescriptor, TIOCSWINSZ, &windowSize)
    }

    /// A blocking read of whatever the terminal has produced. Nil means the child closed its end.
    func read(maximumLength: Int = 65536) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: maximumLength)
        while true {
            let count = Darwin.read(masterFileDescriptor, &buffer, maximumLength)
            if count > 0 { return Array(buffer[0..<count]) }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            // macOS reports a closed slave as EIO rather than a zero-length read.
            if errno == EIO || errno == EBADF { return nil }
            return nil
        }
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                Darwin.write(masterFileDescriptor, raw.baseAddress! + offset, bytes.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            return                                  // the child is gone; the read loop will notice
        }
    }

    func write(_ text: String) {
        write(Array(text.utf8))
    }

    /// Signals the whole session, not just the shell: the negative pid is what reaches the
    /// children a job control shell started.
    func signal(_ signal: Int32) {
        guard processID > 0 else { return }
        kill(-processID, signal)
    }

    /// Reaps the child if it has exited. Nil means it is still running.
    func reapIfExited() -> Int32? {
        var status: Int32 = 0
        let result = waitpid(processID, &status, WNOHANG)
        guard result == processID else { return nil }
        return Self.exitCode(from: status)
    }

    /// A signalled death reports the signal the way a shell does, not the raw wait status.
    private static func exitCode(from status: Int32) -> Int32 {
        if status & 0x7F != 0 { return 128 + (status & 0x7F) }
        return (status >> 8) & 0xFF
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        // Closing the master is also what unblocks a read parked on it, which is how the session
        // stops its read loop without a signal.
        Darwin.close(masterFileDescriptor)
    }

    private static func windowSize(for size: TerminalSize) -> winsize {
        winsize(
            ws_row: UInt16(clamping: size.rows),
            ws_col: UInt16(clamping: size.columns),
            ws_xpixel: UInt16(clamping: size.pixelWidth),
            ws_ypixel: UInt16(clamping: size.pixelHeight))
    }
}

/// The argv and envp arrays must outlive `execve`, so this is a real allocation rather than a
/// temporary conversion. Only the parent frees it; the child replaces its image.
private final class CStringArray {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ values: [String]) {
        count = values.count
        pointers = .allocate(capacity: count + 1)
        for (index, value) in values.enumerated() { pointers[index] = strdup(value) }
        pointers[count] = nil
    }

    deinit {
        for index in 0..<count { free(pointers[index]) }
        pointers.deallocate()
    }
}
