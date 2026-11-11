# Studio CLI installer

Install Studio on macOS, Linux, or Windows Subsystem for Linux (WSL):

```sh
curl -fsSL https://raw.githubusercontent.com/designli/studio-cli/main/install.sh | bash -s -- --url https://designli-studio.lab.designli.io
```

The installer opens Studio sign-in. Enter the eight-character code from your
terminal and approve your own connection with your employee account. It then
downloads the CLI from your authenticated Studio server, verifies its checksum,
installs dependencies, and checks that it matches the server.

You do not need GitHub access, a repository checkout, npm configuration, or an
administrator password. If Node.js 24+ is missing, setup downloads an official
Node.js 24 binary, verifies its SHA-256 checksum, and installs it privately.
Automatic runtime installation supports macOS and Linux on x64 and ARM64.

Follow the final PATH instruction to use `studio` in the current terminal.
Setup also adds it to Bash or Zsh startup configuration. For other shells, add
the printed bin directory to your PATH yourself.

Setup creates a separate employee folder and never rebinds the folder where
you ran it. Existing project bindings and integration credentials are preserved.
Use each project's connection instructions to connect its own working folder.
Rerunning setup reuses a valid employee login. Run `studio update` from a
connected folder for later updates.

This public repository contains only the bootstrap installer. The application,
release artifacts, client data, and credentials are not published here.

To inspect the script before running it:

```sh
curl -fsSL https://raw.githubusercontent.com/designli/studio-cli/main/install.sh -o studio-install.sh
less studio-install.sh
bash studio-install.sh --url https://designli-studio.lab.designli.io
```
