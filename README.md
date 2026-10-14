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

Each chat stays bound to one book and one reading mode: through the current page, through the current chapter, or the whole book. The mode locks after the first question or confirmed summary. Each question refreshes that chat's position; when the same book has no active content, the last verified position is reused and labeled.

- Use `/now` to refresh and display your position locally, or `/now your question` to show it before asking.
- Capture selected text, check the preview, and confirm it before sending. Paragraph fallbacks are labeled explicitly.
- Generate an optional summary for the selected scope. Its progress and result stay with the chat when you navigate elsewhere.
- Source text, summaries, quotes, and history are checked against the current reading boundary. Text within the configured budget is sent in full; larger ranges use explicitly labeled excerpts.

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
