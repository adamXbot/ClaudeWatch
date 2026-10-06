# List available commands
default:
    @just --list

# Run the test suite
[group("dev")]
test:
    swift test

# Copy the shared Settings, menu and About code into this app
[group("dev")]
surfaces:
    python3 .project/mac_surfaces.py sync

# Build the release binary and assemble ClaudeWatch.app (same as CI)
[group("dev")]
build: surfaces
    swift build -c release
    ./build.sh release

# Launch the assembled app
[group("dev")]
run: build
    open ClaudeWatch.app

# Tag v<version> and push it to trigger the sign/notarize/release job
[group("ship")]
release version:
    git tag "v{{version}}"
    git push origin "v{{version}}"

# Remove build outputs
[group("dev")]
clean:
    rm -rf .build ClaudeWatch.app
