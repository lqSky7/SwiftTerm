import Foundation

@main @MainActor enum SSHBootstrapTest {
    static func main() async throws {
        let h = Harness("ssh-bootstrap-test")
        let launcher = "/tmp/path with 'quote/ssh-bootstrap.sh"
        h.expect(RemoteShellBootstrap.submission("ssh person@host", launcher: launcher) != nil, "ordinary SSH bootstrap")
        h.expect(RemoteShellBootstrap.submission("ssh -p 2222 -i /tmp/key -J jump user@host", launcher: launcher) != nil,
                 "connection options preserved")
        for command in ["ssh host ls", "ssh -N host", "ssh -T host", "ssh -L 8080:local:80 host", "ssh $HOST",
                        "ssh host; echo bad", "ssh host\nexit", "ssh -o RemoteCommand=ls host", "ssh -W host:22 jump",
                        "command ssh host", "ssh -o RequestTTY=no host"] {
            h.expect(RemoteShellBootstrap.submission(command, launcher: launcher) == nil, "bypass \(command)")
        }
        let data = Data("dspace dir\0fline\nname\0ctool\0f../bad\0fpartial".utf8)
        let completion = RemoteCompletion(encoded: data.base64EncodedString())
        h.equal(completion.files.count, 2, "bounded NUL manifest skips unsafe and incomplete records")
        h.equal(completion.files[0].name, "space dir", "space name")
        h.equal(completion.commands, ["tool"], "remote commands")
        let resolver = CommandResolver(path: "/usr/bin", remoteCommands: ["remote-only"])
        h.equal(resolver.resolution(of: "remote-only"), .found(path: nil), "remote command resolution")
        h.equal(resolver.resolution(of: "/usr/bin/totally-absent"), .indeterminate, "no local stat on remote path")
        let root = FileManager.default.temporaryDirectory.appending(path: "swiftterm-ssh-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "fixture".write(to: root.appending(path: "remote-file"), atomically: true, encoding: .utf8)
        let mock = root.appending(path: "ssh")
        let mockScript = "#!/bin/sh\nfor arg do last=$arg; done\nexec /bin/sh -c \"$last\"\n"
        try mockScript.write(to: mock, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mock.path)
        let session = try TerminalSession(size: TerminalSize(columns: 90, rows: 25),
            environment: ["SHELL": "/bin/bash", "HOME": root.path, "PATH": root.path + ":/usr/bin:/bin", "TMPDIR": root.path],
            homeDirectory: root.path)
        session.historyStore = CommandHistoryStore(url: root.appending(path: "history.json"))
        defer { session.stop() }
        h.expect(await wait { session.activeBlock?.headerGrid.promptEnd != nil }, "local shell prompt")
        let localDirectory = session.workingDirectory
        session.write(session.submission(for: "ssh test-host"))
        h.expect(await wait { session.remoteHost != nil && session.activeBlock?.isSubmitted == false },
                 "remote bootstrap negotiates prompt")
        h.expect(session.localWorkingDirectory == nil, "remote paths excluded from local Git")
        h.expect(session.remoteCompletion.files.contains { $0.name == "remote-file" }, "actual remote cwd manifest")
        h.expect(session.remoteCompletion.commands.contains("bash"), "remote PATH manifest")
        h.expect(session.blocks.contains { $0.command == "ssh test-host" }, "bootstrap payload excluded from history/header")
        session.write(CommandSubmission.bytes(for: "printf 'REMOTE-ROUNDTRIP\\n'"))
        h.expect(await wait { session.blocks.contains { $0.outputGrid.text.contains("REMOTE-ROUNDTRIP") } },
                 "remote command output")
        session.write(CommandSubmission.bytes(for: "exit"))
        h.expect(await wait { session.remoteHost == nil && session.activeBlock?.isSubmitted == false },
                 "disconnect restores local context")
        h.expect(session.blocks.contains { $0.remoteHost != nil }, "sealed remote blocks retain their origin")
        h.equal(session.restorationDirectory, localDirectory, "restoration retains local context")
        h.equal(session.workingDirectory, localDirectory, "local cwd restored")
        h.expect(!((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).contains {
            $0.hasPrefix("swiftterm-ssh.") }, "remote temporary hooks cleaned")
        let prior = session.activeBlock?.id
        session.write(CommandSubmission.bytes(for: "alias ssh='printf ALIAS_RESULT'"))
        h.expect(await wait { session.activeBlock?.id != prior && session.activeBlock?.isSubmitted == false },
                 "alias command finished")
        h.equal(session.submission(for: "ssh test-host"), CommandSubmission.bytes(for: "ssh test-host"),
                "custom SSH alias bypasses bootstrap")
        h.finish()
    }

    static func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return predicate()
    }
}
