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
