# BooksBridge

BooksBridge is a macOS reading companion for Apple Books. Keep reading in Apple Books and ask an AI assistant about the book, using a selected reading scope to control how much of its content the assistant can access.

## Quick Start

Run these commands from the repository root:

```bash
# Create a local signing identity (one-time setup).
./scripts/setup-signing.sh

# Build and sign the app. Signing failures stop the build;
# the script never silently falls back to ad-hoc signing.
./scripts/build-app.sh

# Launch the app.
./scripts/run-app.sh
```

On first launch:

1. Open **Settings → Permissions** and click **Connect Apple Books**.
2. Grant **Full Disk Access** and **Accessibility** permissions in macOS System Settings.
3. Return to BooksBridge and click **Check Again**.
4. Enter your DeepSeek API key under **Settings → Model & API**.

For details on signing and permission setup, see [Permissions and Signing](docs/permissions.md).

> To verify the app's own permissions, launch it with `./scripts/run-app.sh` or Finder. Running the executable directly from a terminal can use the terminal's TCC permissions, so those results do not establish that BooksBridge itself is authorized.

## Reading Workflow

Open a book in Apple Books, then select it in BooksBridge. Import builds a local chapter map from the EPUB without calling a model or saving another copy of the text.

The summary panel shows whole-book and per-chapter character counts, conservative token estimates, and generation progress. EPUB document counts are listed separately from recognized chapters and other sections. Chapter boundaries come from the local table of contents and headings; unidentified sections remain labeled as such.

For missing or ambiguous chapter structure, open **Summary → Assist chapter organization**. BooksBridge finds candidate boundaries locally, including standalone chapter markers, then asks for confirmation before sending titles, hierarchy, lengths, and small boundary samples (including potentially unread text) to your configured model. Analysis runs in bounded batches and produces a book-wide preview; it never applies changes or generates summaries automatically. Uncertain boundaries remain separate for review. You can apply or discard the proposal, cancel analysis, or restore the local structure. Future titles remain hidden in restricted chats. Books without recognizable markers may still require external source correction; the model cannot invent source positions.

Applying a structure keeps summaries only for unchanged source intervals and invalidates the whole-book summary. Each through-chapter chat must explicitly confirm its revised reading range; through-page positions stay anchored to the original text. Structure proposals and accepted overlays survive navigation and restart, live only in BooksBridge storage, and are associated with the app's book UUID and source fingerprint. Clearing summaries preserves the chapter structure.

Summaries belong to the book and are shared by its chats. Confirm generation to summarize complete chapters within the selected reading mode, saving each completed chapter immediately. Whole-book mode then combines chapter summaries into a book summary. Oversized chapters and summary collections are processed in bounded stages. Configure the model's context window under **Model & API**; generation also respects the request character budget, with space reserved for instructions and output. Token estimates use UTF-8 byte counts conservatively, not a model-specific tokenizer.

Through-page mode uses earlier chapter summaries and the current chapter's already-read text; through-chapter mode includes the current chapter and all earlier chapters. Whole-book mode can use the book summary. Missing summaries fall back to permitted source text or labeled excerpts. Every chat can see shared progress, but future summaries are excluded from restricted chats. Cancelling or restarting retains completed chapters; continuing is manual and reuses them. Deleting a chat retains the book's summaries. Clearing shared summaries requires confirmation.

Apple Books is a read-only source. App-owned book UUIDs, source identifiers, fingerprints, statistics, and summaries are stored under BooksBridge's own Application Support directory; no metadata or summaries are written into the original EPUB or Apple Books database.


Each chat stays bound to one book and one reading mode: through the current page, through the current chapter, or the whole book. The mode locks after the first question or confirmed summary. Each question refreshes that chat's position; when the same book has no active content, the last verified position is reused and labeled.

Use the **+** menu for reading actions. The composer keeps the reading mode, model, and send controls. Reading position and summary status appear after the book/chat names in the top bar; click them to inspect their details. Selected text appears as a confirmation card; summary progress, coverage, and results open in a separate panel.

Press **Enter** to send and **Shift+Enter** for a new line. While generating, click the stop icon or press **Esc twice within 500 ms**. Stopping keeps any partial answer; stopping a retry preserves the original answer.

Small buttons below messages let you copy, edit, or delete a user message, and retry or delete an assistant reply. Editing saves locally; use retry to generate a new answer. A retry refreshes the reading position and uses only history preceding its question, replacing that reply after success. Later messages remain visible after edits, deletions, or retries, but dependent old context is excluded from future model requests. Archived chats are read-only.

Type `/` at the beginning of the input to browse commands. Use the arrow keys and Enter or Tab to select a command, and Esc to dismiss the list.

| Command | Action |
|---|---|
| `/now` | Refresh and display the chat's reading position locally |
| `/now your question` | Refresh the position, then ask your question |
| `/select` | Capture selected text in Apple Books for preview and confirmation |
| `/scope` | Inspect the reading mode, position, and permitted source length |
| `/summary` | View summary progress/results or explicitly generate a summary |
| `/new` | Start another chat for the current book |

Local commands do not require an API key. Generating a summary still requires confirmation before sending source text to the configured model. Source text, summaries, quotes, and history are checked against the current reading boundary. Text within the configured budget is sent in full; larger ranges use explicitly labeled excerpts.

Drag books in the sidebar to reorder them, or use a book's **… → Move up / Move down** menu. The order is saved locally and does not move files in Apple Books. Use a chat's **… → Archive** action to hide it from the regular list. **Settings → Archived** lets you inspect and restore chats, retaining their reading mode, messages, position, and summaries. Running summary jobs continue after a chat is archived.

Book and chat menus include **Rename**. Custom names are saved separately from source titles and automatic chat names; clearing the name restores the default. Archived chats can also be renamed or deleted. Deleting a book requires confirmation and removes its BooksBridge records, cached maps, summary documents, and all chats, including archived chats and saved reasoning. The original book in Apple Books is retained.

Books use stable source identifiers rather than display names. When importing an identical file under another identifier, BooksBridge asks whether to associate it with an existing book or keep it separate. Active-book detection prefers the document's file path; when no path is available, it accepts a unique original-title match. Ambiguous matches require explicit confirmation for the current page.

Chat names use their first verified reading percentage and creation timestamp, for example `42% · 2026-10-15 18:30:00`. They remain stable as you keep reading. A chat without a verified position is labeled with unknown progress until one is available. Existing numbered chats use their saved position and creation time.

Settings save when you switch sections or return to a book/chat in the sidebar. Click the Settings button again to return to the chat. Model-provided reasoning is saved with each reply, including interrupted output, and can be expanded or collapsed manually. The last manual expansion choice is retained; otherwise **Auto-expand reasoning** supplies the default. Reasoning is kept for display and is not included in subsequent model history. Previously unsaved reasoning cannot be recovered.

## Documentation

The detailed documentation is currently in Chinese.

| Document | Contents |
|---|---|
| [Architecture](docs/architecture.md) | Layers, data flow, and the frontend–host contract |
| [Findings](docs/findings.md) | Observations from testing Apple Books and its data formats |
| [Permissions and Signing](docs/permissions.md) | TCC permissions, signing, connection flow, diagnostics, and troubleshooting |
| [Development](docs/development.md) | Building, launch arguments, debugging tools, and code navigation |
| [Known Issues](docs/known-issues.md) | Limitations, tradeoffs, and areas awaiting validation |

## Project Structure

```text
booksbridge/
├── swift/                         # Swift package
│   ├── Sources/
│   │   ├── BooksBridgeCore/        # Apple Books data access, independent of UI and LLM code
│   │   ├── BooksBridgeLLM/         # LLM client, preprocessing, and context assembly
│   │   ├── BooksBridgeApp/         # macOS app host and WKWebView
│   │   │   └── WebUI/             # HTML, CSS, and JavaScript
│   │   ├── booksbridged/           # Command-line driver
│   │   ├── axtree/                 # Accessibility inspection tools
│   │   ├── axmenubar/
│   │   ├── axact/
│   │   └── returnprobe/            # Tests switching back to Apple Books
│   ├── Tests/
│   └── Resources/Info.plist
├── scripts/                       # Build, signing setup, and launch scripts
├── docs/                          # Detailed documentation
├── design/                        # Logo concepts
└── *.py                           # Original Python feasibility prototypes
```
