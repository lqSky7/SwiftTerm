import Foundation

struct RemoteShellBootstrap {
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func submission(_ buffer: String, launcher: String) -> String? {
        guard !buffer.contains("\n"), !buffer.contains("\r") else { return nil }
        let words = buffer.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.first == "ssh" || words.first == "/usr/bin/ssh", words.count >= 2 else { return nil }
        let literal = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@.-/:=,+%[]")
        guard words.allSatisfy({ $0.unicodeScalars.allSatisfy(literal.contains) }) else { return nil }
        var index = 1
        let valued: Set<String> = ["-p", "-l", "-i", "-F", "-J", "-c", "-m", "-b", "-o"]
        let flags: Set<String> = ["-4", "-6", "-A", "-a", "-C", "-v", "-vv", "-vvv", "-q", "-t"]
        while index < words.count, words[index].hasPrefix("-") {
            let option = words[index]
            if flags.contains(option) { index += 1; continue }
            guard valued.contains(option), index + 1 < words.count else { return nil }
            if option == "-o" {
                let key = words[index + 1].split(separator: "=", maxSplits: 1).first?.lowercased() ?? ""
                let safe: Set<String> = ["port", "user", "identityfile", "identitiesonly", "proxyjump",
                    "connecttimeout", "serveraliveinterval", "serveralivecountmax", "stricthostkeychecking",
                    "userknownhostsfile"]
                guard safe.contains(key), words[index + 1].contains("=") else { return nil }
            }
            index += 2
        }
        guard index == words.count - 1, !words[index].hasPrefix("-") else { return nil }
        return "/bin/sh " + quoted(launcher) + " " + words.map(quoted).joined(separator: " ")
    }

    static var launcher: String {
        "#!/bin/sh\ntrap \"printf '\\033]9283;\\007'\" EXIT\nssh_bin=$1\nshift\n\"$ssh_bin\" -t \"$@\" "
            + quoted("sh -c " + quoted(remoteScript))
            + "\nstatus=$?\nexit \"$status\"\n"
    }

    static var remoteScript: String {
        var script = #"""
        umask 077
        directory=$(mktemp -d "${TMPDIR:-/tmp}/swiftterm-ssh.XXXXXXXX") || exec "${SHELL:-/bin/sh}" -i
        trap 'rm -rf "$directory"' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        export SWIFTTERM=1 TERM_PROGRAM=swiftTerm COLORTERM=truecolor
        export SWIFTTERM_USER_ZDOTDIR="${ZDOTDIR:-$HOME}"
        export SWIFTTERM_BOOTSTRAP_ZDOTDIR="$directory"
        export SWIFTTERM_REMOTE_REPORT="$directory/report.sh"
        shell=${SHELL:-/bin/sh}
        printf '\033]9283;%s\007' "$(hostname)"
        """# + "\n"
        script += file(reportScript, named: "report.sh")
        for shell in [ShellType.zsh, .bash, .fish] {
            let name = shell == .zsh ? "zsh" : shell == .bash ? "bash" : "fish"
            let hook = ShellBootstrap.integration(for: shell)
                .replacingOccurrences(of: "  printf '\\e]7;",
                    with: "  /bin/sh \"$SWIFTTERM_REMOTE_REPORT\"\n  printf '\\e]7;")
            script += file(hook, named: "integration." + name)
        }
        for name in ShellType.zshDotFileNames {
            var shim = ShellBootstrap.chainedDotFileShim(named: name)
            if name == ".zshrc" { shim += "\nsource \"$SWIFTTERM_INTEGRATION\"\n" }
            script += file(shim, named: name)
        }
        script += #"""
        case "$shell" in
          */zsh) export ZDOTDIR="$directory" SWIFTTERM_INTEGRATION="$directory/integration.zsh"
                 "$shell" -l -i ;;
          */bash) "$shell" --rcfile "$directory/integration.bash" -i ;;
          */fish) "$shell" -i -C 'source "$SWIFTTERM_BOOTSTRAP_ZDOTDIR/integration.fish"' ;;
          *) "$shell" -i ;;
        esac
        status=$?
        exit "$status"
        """# + "\n"
        return script
    }

    private static func file(_ text: String, named name: String) -> String {
        "cat >\"$directory/" + name + "\" <<'SWIFTTERM_HOOK_EOF'\n" + text + "\nSWIFTTERM_HOOK_EOF\n"
    }

    static let reportScript = #"""
    directory=$SWIFTTERM_BOOTSTRAP_ZDOTDIR
    if [ ! -f "$directory/commands" ] || [ "$(cat "$directory/path" 2>/dev/null)" != "$PATH" ]; then
      printf '%s' "$PATH" > "$directory/path"
      (
        IFS=:
        count=0
        for location in $PATH; do
          [ -n "$location" ] || continue
          for entry in "$location/"*; do
            count=$((count + 1))
            [ "$count" -le 10000 ] || break 2
            [ -f "$entry" ] && [ -x "$entry" ] && printf 'c%s\000' "${entry##*/}"
          done
        done
      ) | head -c 20000 > "$directory/commands"
    fi
    payload=$(
      (
        count=0
        for entry in "$PWD/"* "$PWD/".[!.]* "$PWD/"..?*; do
          [ -e "$entry" ] || [ -L "$entry" ] || continue
          count=$((count + 1))
          [ "$count" -le 500 ] || break
          if [ -d "$entry" ]; then printf 'd%s\000' "${entry##*/}"
          else printf 'f%s\000' "${entry##*/}"; fi
        done
        cat "$directory/commands"
      ) | head -c 40000 | base64 | tr -d '\r\n'
    )
    printf '\033]9284;%s\007' "$payload"
    """#
}
