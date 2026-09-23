# Warp Feature Catalog & Architectural Deep-Dive

---

## Batch 1: Core Terminal Experience & Rendering (1 – 10)

### 1. Command Blocks (Discrete Block-Based Terminal Architecture)
* **High-Level Description:** Instead of rendering an endless, unstructured scrolling stream of text where output blends into subsequent prompts, every command execution and its output are encapsulated into a distinct, standalone "Block". Each block has its own metadata header (timestamp, working directory, git branch, execution status, runtime duration) and isolated output canvas.
* **Under the Hood:** 
  * Warp injects custom shell hooks into the PTY session (`precmd` and `preexec`).
  * On command start, `warp_preexec` transmits the executed command string.
  * On command finish, `warp_precmd` captures the exit code (`$?`) and sends structured DCS/OSC hook messages (`CommandFinished` and `Precmd`) with `exit_code`, `next_block_id`, and prompt state.
  * The terminal core maintains an indexed list of `BlockGrid` objects. When a command finishes, that block's grid is sealed as immutable, and a new block is readied for the next command.
* **Relevant Warp Files:**
  * `crates/warp_terminal/src/model/blockgrid.rs`
  * `app/src/terminal/model/blocks.rs`
  * `app/src/terminal/model/block.rs`
  * `crates/warp_terminal/src/model/ansi/dcs_hooks.rs`
  * `app/assets/bundled/bootstrap/zsh_body.sh`
  * `app/assets/bundled/bootstrap/bash_body.sh`

---

### 2. Decoupled Text Editor Input (IDE-Grade Command Line Editing)
* **High-Level Description:** Typing in Warp behaves like typing in a modern code editor (VS Code, Sublime, Xcode) rather than a raw terminal. It supports mouse cursor positioning anywhere in the text, multi-line editing with shift+enter, native undo/redo (`⌘Z` / `⇧⌘Z`), text selections, word-jumping (`⌥←` / `⌥→`), and Vim modal editing.
* **Under the Hood:**
  * Warp hides/disables the shell's built-in line editors (`readline` in bash, `zle` in zsh).
  * The input area at the bottom is a dedicated GUI text editor (`crates/editor`) decoupled from the terminal's character grid.
  * When the user presses Enter to run a command, Warp clears any residual line editor state in the background shell using control sequences (`Ctrl-U` + `Ctrl-K`) and streams the complete buffer into the PTY along with a carriage return (`\r`).
* **Relevant Warp Files:**
  * `crates/editor/src/`
  * `app/src/editor/`
  * `app/src/terminal/view.rs` (specifically `clear_line_editor_and_write_to_pty`)
  * `crates/vim/src/`

---

### 3. GPU-Accelerated Text & UI Rendering Pipeline
* **High-Level Description:** 60/120 FPS ultra-low-latency graphics rendering across all UI elements, text glyphs, starry/cosmic background textures, context badges, and block borders directly on the GPU without web views or DOM overhead.
* **Under the Hood:**
  * Uses `wgpu` (Metal on macOS, Vulkan/DirectX on Linux/Windows) with custom WGSL shaders:
    * `glyph_shader.wgsl`: Uses luminance-scaled contrast enhancement (`enhance_contrast`) to prevent light-on-dark text thinning. Glyphs are rasterized into a dynamic 2D Glyph Atlas texture with subpixel positioning using Core Text and snapped vertically to the pixel grid.
    * `rect_shader.wgsl`: Single-pass shader rendering rounded corners, drop shadows, borders, and gradient fills in a single draw call.
    * `image_shader.wgsl`: Renders terminal graphics, inline images, and background textures.
* **Relevant Warp Files:**
  * `crates/warpui/src/rendering/wgpu/shaders/glyph_shader.wgsl`
  * `crates/warpui/src/rendering/wgpu/shaders/rect_shader.wgsl`
  * `crates/warpui/src/rendering/wgpu/shaders/image_shader.wgsl`
  * `crates/warpui/src/rendering/atlas/`
  * `crates/warpui_core/src/text_layout.rs`
  * `crates/warpui/src/rendering/wgpu/renderer.rs`

---

### 4. Intelligent Autosuggestions & Text Prediction
* **High-Level Description:** Real-time predictive typing that offers both fish-style inline ghost text (pressing `Right Arrow` or `Tab` accepts) and a rich autocomplete popover showing commands, flags, arguments, files, and recent history with contextual descriptions.
* **Under the Hood:**
  * Powered by `crates/warp_completer` and `app/src/input_suggestions.rs`.
  * Suggestion engine aggregates multiple sources:
    1. **Command Signatures:** Over 500+ CLI specs (`command-signatures-v2`) defining subcommands, flags, option types, and descriptions for tools (`git`, `docker`, `cargo`, `npm`, `kubectl`).
    2. **Local Path Engine:** Real-time directory traversal and fuzzy path matching (`path.rs`).
    3. **History Engine:** Indexed session history and shell histfile records.
    4. **Subshell Completion Generators:** Spawns background completion workers to invoke native shell completion engines for un-modeled tools.
* **Relevant Warp Files:**
  * `crates/warp_completer/src/completer/engine/`
  * `crates/warp_completer/src/completer/suggest/`
  * `crates/warp_completer/src/signatures/`
  * `app/src/input_suggestions.rs`
  * `command-signatures-v2/`

---

### 5. Shell Integration & PTY State Hooks
* **High-Level Description:** Deep two-way synchronization between the shell environment (`zsh`, `bash`, `fish`) and the terminal emulator. Warp automatically tracks directory changes, git branch updates, environment variables, exit codes, and execution timings without scraping screen text.
* **Under the Hood:**
  * Shell integration scripts (`app/assets/bundled/bootstrap/`) are sourced during shell initialization.
  * Intercepts shell lifecycle hooks:
    * `precmd`: Runs before each prompt display; packages `$?`, `$PWD`, git branch/status, virtualenv, conda env, node version, and emits them over PTY as hex-encoded JSON in Device Control String (`DCS`) escape sequences (`\eP$d...`).
    * `preexec`: Runs right before command execution; records raw command string and timestamp.
  * The terminal ANSI parser decodes DCS/OSC payloads into strongly-typed structures (`PromptMetadata`, `CommandFinishedValue`).
* **Relevant Warp Files:**
  * `app/assets/bundled/bootstrap/zsh_body.sh`
  * `app/assets/bundled/bootstrap/bash_body.sh`
  * `app/assets/bundled/bootstrap/fish.sh`
  * `crates/warp_terminal/src/model/ansi/dcs_hooks.rs`
  * `crates/warp_terminal/src/model/ansi/control_sequence_parameters.rs`

---

### 6. Real-Time Command Validation & Syntax Highlighting
* **High-Level Description:** As commands are typed into the input buffer, syntax is colored in real-time (commands, subcommands, flags, strings, operators). Unrecognized commands or invalid paths are flagged with a red dashed underline before the user even hits Enter.
* **Under the Hood:**
  * Integrates Tree-sitter parsers to parse the command string into a concrete syntax tree.
  * Cross-checks command tokens against:
    1. Built-in shell keywords and aliases captured during bootstrap.
    2. System `$PATH` executable binaries.
  * If a command binary is not found, the editor attaches a diagnostic squiggly marker, which is rendered on the GPU by passing `dashed_border_data` into `rect_shader.wgsl`.
* **Relevant Warp Files:**
  * `crates/syntax_tree/`
  * `crates/languages/`
  * `app/src/input_suggestions.rs`
  * `crates/warpui/src/rendering/wgpu/shaders/rect_shader.wgsl`

---

### 7. Interactive Context Chips (Smart Prompt Badges)
* **High-Level Description:** Clean badge capsules displayed above or inside the prompt bar showing real-time environment status:
  * Runtime versions (e.g. `[js v26.9.0]`, Python, Ruby)
  * Current Directory (e.g. `[~/Projects/personal/leetFeedback/website]`)
  * Git Branch (e.g. `[main]`)
  * Git Ahead/Behind & Diff stats (e.g. `[10 • +1403 -277]`)
* **Under the Hood:**
  * Data is harvested by shell bootstrap hooks and delivered via `PromptMetadata`.
  * Rendered as clickable interactive UI widgets (`app/src/context_chips/`). Clicking a chip opens context menus (e.g., clicking the git branch allows switching branches, clicking folder allows copying path or revealing in Finder).
* **Relevant Warp Files:**
  * `app/src/context_chips/`
  * `app/src/context_chips/builtins.rs`
  * `app/src/prompt/`
  * `crates/warp_terminal/src/model/ansi/dcs_hooks.rs`

---

### 8. Granular Block Context Menu & Actions
* **High-Level Description:** Right-clicking on any finished command block presents actions scoped specifically to that command's execution:
  * Copy Command (`⇧⌘C`), Copy Output (`⌥⇧⌘C`), Copy Prompt, Copy Working Directory, Copy Git Branch.
  * Find within block (`⌘F`), Filter block output (`⌥⇧F`), Toggle bookmark (`⌘B`).
   Share block (`⇧⌘S`) ( [for later, we will write our own backend and website!]).
* **Under the Hood:**
  * Because blocks are isolated data models with independent input strings, output buffers, exit codes, and timestamps, actions operate on clean data without manual text selection or screen scraping.
  * Text copy operations support plain text, stripped ANSI, and formatted Markdown.
* **Relevant Warp Files:**
  * `app/src/terminal/view.rs`
  * `crates/warp_terminal/src/model/selection.rs`
  * `crates/warp_terminal/src/model/blockgrid.rs`

---

### 9. Secure Block Sharing & Permalinks [for later, we will write our own backend and website!]
* **High-Level Description:** Users can export or share any command block (or sequence of blocks) as a public/private web link or clean snapshot to share with colleagues or debug in documentation.
* **Under the Hood:**
  * The block's command text, exit code, and terminal grid contents are serialized to structured JSON.
  * Automatically runs through the Secret Redaction pipeline to mask sensitive data before publishing to Warp Drive cloud services (`crates/cloud_objects`).
* **Relevant Warp Files:**
  * `crates/cloud_objects/`
  * `crates/cloud_object_client/`
  * `crates/secret_redaction/`
  * `app/src/cloud_object/`

---

## Batch 2: Workflows, AI, Security & Window Architecture (11 – 20)


### 14. Automatic Secret Redaction & Masking  [for later, we will write our own backend and website!]
* **High-Level Description:** Prevents accidental leakage of sensitive credentials (AWS access keys, GitHub personal access tokens, OpenAI API keys, SSH private keys, passwords) by detecting and masking them with asterisks (`*`) in the terminal output and when sharing blocks.
* **Under the Hood:**
  * Uses compiled multi-pattern Regex DFAs (`crates/regex_dfas`) to scan incoming terminal text during grid ingestion without impacting streaming throughput.
  * Stores secrets in an obfuscated state in memory (`crates/managed_secrets`); allows users to reveal masked text on demand with explicit authorization.
* **Relevant Warp Files:**
  * `crates/secret_redaction/src/lib.rs`
  * `crates/managed_secrets/`
  * `crates/warp_terminal/src/model/secrets.rs`

---

### 15. Universal Omnibar / Global Command Palette
* **High-Level Description:** A centralized top search bar ("Search sessions, agents, files...") and Command Palette (`⌘k`) allowing instant navigation to any tab, open pane, historical command, workflow, file, or setting.
* **Under the Hood:**
  * Queries an in-memory unified search index (`warp_search_core`) with fuzzy string matching (`fuzzy_match`).
  * Surfaces categorized action items with hotkey hints and real-time result previewing.
* **Relevant Warp Files:**
  * `app/src/search_bar.rs`
  * `app/src/command_palette.rs`
  * `crates/warp_search_core/`
  * `crates/fuzzy_match/`

---

### 16. Rich Left Sidebar & Tab Manager
* **High-Level Description:** A vertical sidebar managing tabs and sessions with rich visual metadata:
  * Foreground running process name (e.g. `npm`, `cargo`)
  * Working directory path
  * Git branch & uncommitted change counts (`+1394 -276`)
  * Tab search, quick reordering, and direct hotkey switching (`⌘1`, `⌘2`, ...).
* **Under the Hood:**
  * Each tab tracks its root pane group, active session ID, and process tree watcher.
  * Emits state changes whenever child PTY hooks or git status file watchers trigger updates.
* **Relevant Warp Files:**
  * `app/src/tab.rs`
  * `app/src/session_management.rs`
  * `app/src/root_view.rs`

---

### 18. Session Restoration & Crash Recovery
* **High-Level Description:** If the terminal quits unexpectedly or restarts for an update, Warp automatically restores open windows, tabs, split pane layouts, working directories, and historical command blocks without losing context.
* **Under the Hood:**
  * State is continuously persisted into a local SQLite database (`crates/persistence`) using Diesel ORM.
  * Employs an external watchdog/crash supervisor process (`app/src/crash_recovery.rs`) to detect panics and cleanly recover session states.
* **Relevant Warp Files:**
  * `app/src/crash_recovery.rs`
  * `crates/persistence/src/schema.rs`
  * `crates/persistence/src/model.rs`
  * `app/src/session_management.rs`

---

### 19. Automatic SSH & Remote Session Bootstrapping
* **High-Level Description:** When connecting to a remote machine via `ssh user@host`, Warp seamlessly propagates block-based formatting, context badges, and autocompletion onto the remote host without requiring manual remote agent installation.
* **Under the Hood:**
  * Detects outgoing SSH invocations in `crates/remote_server`.
  * Injects an inline bootstrap script (`install_remote_server.sh` / `ssh.rs`) over the SSH connection to stream DCS/OSC hooks back to the local client over the multiplexed SSH channel.
* **Relevant Warp Files:**
  * `crates/remote_server/src/manager.rs`
  * `crates/remote_server/src/ssh.rs`
  * `crates/remote_server/src/transport.rs`
  * `app/src/remote_server/`

---

### 20. Warp Notebooks (Executable Markdown Runbooks)
* **High-Level Description:** Interactive documents that blend rich Markdown documentation (headings, lists, descriptions, links) with executable command blocks that can be executed directly inside the terminal.
* **Under the Hood:**
  * Parses Jupyter notebook (`.ipynb`) and Markdown runbooks (`crates/ipynb_parser`).
  * Embeds live `crates/editor` blocks directly within the rendered document layout; output is captured back into the notebook's block stream.
* **Relevant Warp Files:**
  * `app/src/notebooks/notebook.rs`
  * `app/src/notebooks/editor/`
  * `crates/ipynb_parser/`
  * `app/src/notebooks/manager.rs`

---

## Batch 3: Modal Editing, Media, Themes & Git Integration (21 – 30)
---

### 23. Terminal Graphics Protocols (Kitty & iTerm2 Image Support)
* **High-Level Description:** Renders inline images, diagrams, matplotlib charts, and terminal graphics directly inside command blocks, enabling rich graphical output for CLI tools like `viu`, `icat`, `fastfetch`, and data science scripts.
* **Under the Hood:**
  * Fully implements the Kitty Graphics Protocol (`crates/warp_terminal/src/model/kitty.rs`) and iTerm2 OSC 1337 image protocol (`iterm_image.rs`).
  * Decodes base64 payload streams into compressed textures in `warpui_core::image_cache`, and paints them into the block layout using `image_shader.wgsl`.
* **Relevant Warp Files:**
  * `crates/warp_terminal/src/model/kitty.rs`
  * `crates/warp_terminal/src/model/iterm_image.rs`
  * `crates/warpui/src/rendering/wgpu/shaders/image_shader.wgsl`
  * `crates/warpui_core/src/image_cache.rs`

---

### 24. Custom Theme Engine & Procedural Background Shaders
* **High-Level Description:** Comprehensive theme system supporting light and dark modes, standard 16-color ANSI palettes, custom font typography, background opacity, window blur, and animated/static procedural background images (like the cosmic starfield visible in the screenshots).
* **Under the Hood:**
  * Themes are defined in declarative YAML/JSON files (`ThemeConfig`).
  * Features an in-app visual Theme Creator (`theme_creator.rs`) allowing real-time color editing.
  * Shaders blend background texture maps with terminal cell layers using alpha transparency.
* **Relevant Warp Files:**
  * `app/src/themes/theme.rs`
  * `app/src/themes/theme_chooser.rs`
  * `app/src/themes/theme_creator_body.rs`
  * `app/src/appearance.rs`

---

### 25. Launch Configurations (Declarative Workspaces)
* **High-Level Description:** Allows saving multi-window, multi-tab, and multi-split pane layouts into reusable YAML configuration files. Launching a config immediately boots up complex dev setups (e.g. backend server, frontend bundler, database logs, and git status panes in predetermined directories with startup commands).
* **Under the Hood:**
  * `app/src/launch_configs/launch_config.rs` serializes pane tree hierarchies, working directory URIs, tab titles, and startup shell commands.
  * The launch runner orchestrates parallel PTY creation and runs startup scripts sequentially upon window initialization.
* **Relevant Warp Files:**
  * `app/src/launch_configs/launch_config.rs`
  * `app/src/launch_configs/save_modal.rs`
  * `app/src/tab_configs/`

---

### 26. Built-in Git Code Review & Diff Viewer
* **High-Level Description:** A full Git pull request and diff review tool integrated directly into Warp. Developers can inspect uncommitted changes, view side-by-side or unified diffs, stage/unstage hunks, and view GitHub PR reviews and comments without switching to a browser. NOTE that it opens as a right "sidebar"
* **Under the Hood:**
  * Implemented in `app/src/code_review/` (over 300KB of review logic).
  * Hooks into local Git repositories via `libgit2` / CLI git wrappers, reads tree diffs, maps file modifications into syntax-highlighted editor diff views, and syncs comments via GitHub GraphQL APIs.
* **Relevant Warp Files:**
  * `app/src/code_review/code_review_view.rs`
  * `app/src/code_review/comment_list_view.rs`
  * `app/src/code_review/diff_menu.rs`
  * `app/src/code_review/git_actions.rs`

---

### 27. Local Control Daemon & CLI IPC Protocol [planned for later not now]
* **High-Level Description:** A local daemon and IPC socket interface that allows external terminal scripts, shell aliases, or third-party tools to control Warp via the `warp` CLI tool (e.g. `warp open`, `warp notify`, programmatic tab creation).
* **Under the Hood:**
  * `crates/local_control` listens on a local Unix domain socket (or named pipe on Windows).
  * Implements an authenticated JSON-RPC protocol (`protocol.rs`) allowing external processes to query terminal window state, open tabs, trigger commands, or send notifications.
* **Relevant Warp Files:**
  * `crates/local_control/src/protocol.rs`
  * `crates/local_control/src/client.rs`
  * `crates/local_control/src/discovery.rs`
  * `crates/warp_cli/`

---

### 30. Granular Keymap Configuration & Keyboard Navigation
* **High-Level Description:** Complete control over all keyboard shortcuts, key combinations, and modal bindings. Includes block jumping (`⌘↑` to jump to previous command block, `⌘↓` to jump forward), quick command palette, and vim/emacs navigation schemes.
* **Under the Hood:**
  * Managed by `crates/warpui_core/src/keymap.rs` and `app/src/keyboard.rs`.
  * Normalizes key events across macOS (NSEvent), Windows, and Linux into a unified Action dispatch system.
* **Relevant Warp Files:**
  * `crates/warpui_core/src/keymap.rs`
  * `app/src/keyboard.rs`
  * `app/src/menu.rs`

---

## Batch 4: Collaboration, System Integration & Terminal Protocols (31 – 40)

### 31. Live Multiplayer Shared Sessions [planned for later, not now]
* **High-Level Description:** Real-time terminal session sharing allowing multiple developers to view a terminal live, follow outputs together, or pair-program with co-typing capabilities and avatar indicators for connected team members.
* **Under the Hood:**
  * Built inside `app/src/terminal/shared_session/`.
  * Implements a peer-to-peer or relay network protocol (`network.rs`, `presence_manager.rs`) that replicates PTY input events and terminal grid damage diffs.
  * Supports role-based access control (read-only observer vs interactive co-pilot with write permissions).
* **Relevant Warp Files:**
  * `app/src/terminal/shared_session/presence_manager.rs`
  * `app/src/terminal/shared_session/participant_avatar_view.rs`
  * `app/src/terminal/shared_session/sharer/`
  * `app/src/terminal/shared_session/viewer/`

---

### 32. Alternate Screen Buffer Switching (TUI Fullscreen Mode)
* **High-Level Description:** Smooth, automatic transition between Warp's modern Block-based layout and traditional fullscreen terminal applications (such as `vim`, `htop`, `tmux`, `nano`, `less`).
* **Under the Hood:**
  * Intercepts `CSI ? 1049 h` (enter alternate screen) and `CSI ? 1049 l` (exit alternate screen).
  * In alt screen mode, Warp replaces the block scroll view with a full-viewport raw 2D grid (`AltScreen`), suppresses the detached editor input, and routes raw keystrokes directly to the PTY.
  * On exit, Warp smoothly restores the block view and re-enables the decoupled text editor.
* **Relevant Warp Files:**
  * `app/src/terminal/model/alt_screen.rs`
  * `crates/warp_terminal/src/model/mode.rs`
  * `app/src/terminal/view.rs`

---

### 33. OSC 8 Hyperlink Protocol & Clickable File Paths
* **High-Level Description:** Any URL or standard file path printed in the terminal (e.g. `https://warp.dev` or `src/main.rs:42`) becomes an interactive link. Hovering underlines the link, and `⌘-Click` opens the URL in a browser or jumps directly to the file and line number in your code editor.
* **Under the Hood:**
  * Implements the OSC 8 explicit hyperlink protocol (`\e]8;;URL\e\ ... \e]8;;\e\`) managed in `hyperlink_registry.rs`.
  * Automatically applies regex path matchers to detect implicit file paths, URLs, and git commit hashes on grid lines.
* **Relevant Warp Files:**
  * `crates/warp_terminal/src/model/grid/hyperlink_registry.rs`
  * `crates/warp_terminal/src/model/grid/grid_handler.rs`
  * `app/src/terminal/view.rs`

---

### 38. Automatic Git Project Detection & Root Scoping
* **High-Level Description:** When navigating into a project folder, Warp automatically detects the enclosing Git repository, language toolchain (Node, Rust, Python, Go), and scopes command history and autocomplete searches to the active project root.
* **Under the Hood:**
  * `crates/repo_metadata` monitors filesystem directory changes and searches parent directories for `.git` anchors and project manifests (`package.json`, `Cargo.toml`, `pyproject.toml`).
  * Associates active tabs with project context (`app/src/projects.rs`).
* **Relevant Warp Files:**
  * `crates/repo_metadata/`
  * `app/src/projects.rs`
  * `crates/watcher/`

---

### 39. Word Block Editor (Interactive Token Manipulation)
* **High-Level Description:** Allows treating command line arguments as interactive visual "word pills" or blocks. Users can click to select, delete, reorder, or swap arguments with ease instead of mashing backspace.
* **Under the Hood:**
  * `app/src/word_block_editor.rs` parses the raw input string into token boundaries.
  * Renders each word/argument inside a bounded hoverable chip inside the text editor layout.
* **Relevant Warp Files:**
  * `app/src/word_block_editor.rs`
  * `crates/editor/src/`

---


## Batch 5: System Integration, Headless TUI & Desktop Shell (41 – 50)

### 41. Headless Console TUI Mode
* **High-Level Description:** A full terminal-based text user interface (`crates/warp_tui`) allowing Warp to run in environments without a graphical window server (such as remote headless cloud VMs, containers, or over pure SSH).
* **Under the Hood:**
  * Uses a cell-grid element framework (`crates/warpui_core/src/elements/tui/`) implementing the `TuiElement` trait.
  * Translates crossterm terminal events into Warp Actions, rendering blocks, menus, and agents into a cell-grid `TuiBuffer`.
* **Relevant Warp Files:**
  * `crates/warp_tui/src/`
  * `crates/warp_tui/src/terminal_session_view.rs`
  * `crates/warp_tui/src/agent_block.rs`
  * `crates/warpui_core/src/elements/tui/`

---

### 42. Embedded Fast Ripgrep Search Engine
* **High-Level Description:** Lightning-fast text search across gigabytes of terminal logs, session history, and local project files using multi-threaded regex search.
* **Under the Hood:**
  * Directly embeds the BurntSushi Ripgrep search library inside `crates/warp_ripgrep`.
  * Allows instantaneous substring and regex searching through millions of lines of historical output without freezing the main UI thread.
* **Relevant Warp Files:**
  * `crates/warp_ripgrep/`
  * `crates/warp_search_core/`

---

### 43. Subsequence Fuzzy Matcher
* **High-Level Description:** Intelligent fuzzy-ranking algorithm that powers autocomplete matching and omnibar navigation, prioritizing prefix matches, word boundaries, camelCase transitions, and path separators (`/`).
* **Under the Hood:**
  * `crates/fuzzy_match` scores candidate strings against query patterns by calculating contiguous match bonuses, word boundary weights, and acronym matching.
* **Relevant Warp Files:**
  * `crates/fuzzy_match/src/lib.rs`
  * `app/src/input_suggestions.rs`

---

### 45. In-App Contextual Banner & Notification System
* **High-Level Description:** Displays non-modal, dismissible notification banners at the top of the terminal window for product announcements, network connection losses, offline mode alerts, and shell upgrade recommendations.
* **Under the Hood:**
  * Managed by `app/src/banner/`.
  * Banners animate into view, adjust the vertical constraint bounds of the underlying terminal pane tree, and persist dismissal state into local user preferences.
* **Relevant Warp Files:**
  * `app/src/banner/`
  * `app/src/root_view.rs`

---

### 47. Active Process Quit & Close Safety Protection
* **High-Level Description:** Protects against accidental data loss or disrupted deployments by prompting for confirmation before closing tabs or quitting the app when active processes (compilers, long scripts, servers, SSH sessions) are running.
* **Under the Hood:**
  * `app/src/quit_warning/` inspects the active process tree of each pane's PTY master file descriptor using system process table APIs (`libproc` on macOS).
  * If non-shell child processes are detected, it presents a modal confirmation dialogue enumerating the active running commands.
* **Relevant Warp Files:**
  * `app/src/quit_warning/mod.rs`
  * `app/src/tab.rs`

---

### 48. Undo Closed Tab & Split Pane Restoration (`⇧⌘T`)
* **High-Level Description:** Restores accidentally closed tabs or split panes with `⇧⌘T`, instantly recovering the pane split layout, working directory, process command, and previous block scrollback.
* **Under the Hood:**
  * `app/src/undo_close/stack.rs` maintains an in-memory LIFO stack of closed pane configurations.
  * When triggered, pops the most recent pane snapshot and re-inserts it into the pane tree, restoring its historical blocks from SQLite.
* **Relevant Warp Files:**
  * `app/src/undo_close/stack.rs`
  * `app/src/undo_close/mod.rs`
---

## Batch 6: Advanced Developer Tooling, Sandboxing & Privacy (51 – 60)

### 53. Directory Color Tagging
* **High-Level Description:** Visually tag specific folders and repositories with custom colors. When navigating into a tagged directory, the tab header, context chips, and border highlights change to match the assigned color (e.g. red for production servers, blue for frontend).
* **Under the Hood:**
  * `app/src/settings_view/directory_color_add_picker.rs` maintains a path-to-color mapping table.
  * When `PromptMetadata` reports directory changes (`pwd`), the theme engine overlays the directory accent color onto the tab and prompt views.
* **Relevant Warp Files:**
  * `app/src/settings_view/directory_color_add_picker.rs`
  * `app/src/tab.rs`
