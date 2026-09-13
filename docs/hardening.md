# What the daemon trusts

`mdrctld` is long-lived, runs for the whole session, and listens on a socket
any process owned by the same user can open. That combination is what makes the
questions below worth answering: not "is this reachable from the internet" — it
is not — but "what can something already on this machine, running as this user,
make it do".

This is the record of what it stopped trusting, prompted by a security review on
the Omarchy plugin marketplace submission. Each section says what was wrong,
what it is now, and what holds it there.

## The environment

**Was.** The daemon read `MDR_BUILD`, `MDR_TRACE` and `MDR_MAC` from its
environment and inherited the rest. The sharp one was `MDR_BUILD`: it named the
directory the two shared objects are loaded from, and `Library.find()` consulted
it *before* the packaged location. Anything that could set the environment of
the service chose which `libmdr-shared.so` got `dlopen`ed — which is to say,
chose the code the daemon ran. `MDR_TRACE` was an arbitrary path opened for
append. The interpreter came from `#!/usr/bin/env python3`, and `busctl` was
invoked by bare name, so an inherited `PATH` selected both.

**Is.** Configuration arrives as arguments — `--mac`, `--build-dir`, `--trace` —
because an argument is something the unit states and an environment is something
it is handed. `Library.find()` no longer looks at any variable. The unit names an
absolute interpreter and an absolute script, sets `PATH=/usr/bin:/bin`, and
clears `MDR_BUILD MDR_TRACE MDR_MAC LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT
PYTHONPATH PYTHONHOME PYTHONSTARTUP`. `busctl` is resolved from a fixed list of
absolute paths and must be a regular executable file.

`XDG_RUNTIME_DIR` is still read, because it is the only way a service learns
where its private directory is. The answer to that is to verify the directory,
which is the next section.

**Held by.** `ToolTest` asserts the busctl candidates are absolute. The developer
tools under `daemon/tools/` still accept `MDR_BUILD` and pass it explicitly —
they are short-lived instruments run by hand, not a service, and the library no
longer picks the variable up on its own.

## The runtime directory

**Was.** Every operation named a path. `os.makedirs`, then `os.path.exists`,
then `os.unlink`, then `bind` — each one re-walking
`$XDG_RUNTIME_DIR/mdrctl/...` and each one a fresh opportunity for a component
to have become something else in between. Startup unlinked whatever was at the
socket path without asking what it was. `state.json` was written through
`open(path, "w")`, which follows a symlink to wherever it points.

**Is.** The directory is opened once with `O_DIRECTORY|O_NOFOLLOW`, its owner
checked against `getuid()`, its mode tightened if it is loose, and the
descriptor held for the life of the process. Every subsequent create, replace
and unlink passes `dir_fd=`, so names resolve inside the directory *object* that
was checked rather than through a path that is walked again. The temp file is
created `O_EXCL|O_NOFOLLOW` at mode 0600, so a link planted at `state.json.new`
is removed and replaced rather than written through. The socket is removed only
after `lstat` confirms it is a socket; anything else wearing that name makes the
daemon exit rather than delete someone's file. `bind()` has no `dir_fd` form, so
it binds relative to the verified descriptor under a 0077 umask.

Under systemd the directory is created by `RuntimeDirectory=mdrctl` with
`RuntimeDirectoryMode=0700`, so the daemon is no longer creating the anchor it
then trusts — it verifies one that already exists. Run by hand it creates its
own, and checks it the same way.

**Held by.** `RuntimeDirTest` — private on creation, tightened when found loose,
refuses a symlinked directory, does not follow a planted link, publishes 0600.

## What one client can make it hold

**Was.** `serve_subscriber` appended every 4096-byte read to a per-connection
buffer and only looked for a newline. A client that connected and sent bytes
without ever sending one made the daemon hold all of them, indefinitely, and
nothing limited how many such connections there could be.

**Is.** A buffered line over `MAX_LINE` (64 KiB) drops the connection — a
command is a short line and anything larger is not one. `MAX_CLIENTS` (32) is
refused at `accept()` rather than queued. A connection holding an *incomplete*
line for longer than `PARTIAL_LINE_WAIT` (30 s) is collected; a subscriber
sitting silent with nothing buffered is normal and stays, which is what the bar
widget does all day.

`busctl`'s output is read through a pipe with a `MAX_TOOL_OUTPUT` (4 MiB)
ceiling instead of `capture_output=True`, which buffers whatever the child
decides to produce.

**Held by.** `ClientLimitTest` — an unterminated line is cut off, a normal
command still gets through. `ToolTest` — output is capped, normal output
survives.

## Where the code comes from

**Was.** `scripts/install.sh` wrote a unit pointing `ExecStart` straight at the
checkout, so a service executed a directory you edit, rebase and pull. The
first answer to that staged a copy into `$XDG_DATA_HOME/mdrctl` and pointed the
unit there, which was better but not actually the property being asked for:
that directory is still writable by the user the daemon runs as.

**Is.** There is no install script. The package is the only path, and it
installs to `/usr/bin/mdrctld` and `/usr/lib/mdrctl`, which that user cannot
write to. Omarchy is Arch, so this costs nobody anything -- everyone who can
install the widget already has `makepkg`, and the script was a worse duplicate
of what the package does: not pacman-managed, not removable with `pacman -Rns`.

The scripts were removed for a second reason worth recording, because it says
something about fixing things to satisfy a checker. `scripts/build-libmdr.sh`
fetched the upstream library, and the marketplace baseline reported it as
`remote-git-execution-unpinned` through four attempts -- including one where
the fetch named a literal URL and a literal 40-character commit and checked it
out detached, which is its own stated fix, written out. The matcher objects to
fetch-then-build as a shape, not to how it is pinned. The honest move at that
point was not a fifth wording but to ask who the script was for, and the answer
was nobody: it served non-Arch users of a plugin that only installs on Arch.

`makepkg` still builds that upstream commit, pinned in the `PKGBUILD` source
array. The build did not disappear; it stopped being expressed as a shell
script. If that is ever read the same way, the real escape is a daemon with no
C++ dependency at all.

## The rest of the unit

`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=read-only`,
`ProtectProc=invisible`, the `Protect*` kernel set, `RestrictSUIDSGID`,
`RestrictRealtime`, `RestrictNamespaces`, `LockPersonality`,
`SystemCallArchitectures=native`, `SystemCallFilter=@system-service`, an empty
`CapabilityBoundingSet`, `MemoryMax=128M` and `TasksMax=32`.

`RestrictAddressFamilies=AF_UNIX AF_BLUETOOTH AF_NETLINK` — the socket the
widget uses and D-Bus, the RFCOMM link to the headset, and how BlueZ reports the
adapter coming and going. `busctl` was verified to work under the full set
rather than assumed to, because a silent failure there is indistinguishable from
headphones that are simply switched off.

`MemoryDenyWriteExecute` is deliberately not set: `ctypes` uses libffi closures,
which need it off on some builds, and a directive that breaks the daemon on
someone else's machine is worse than the one it prevents.

## What this does not claim

Nothing here defends against an attacker who already runs as this user with a
debugger — they own the process regardless. The aim is narrower and worth
stating plainly: no input from the socket should be able to exhaust the machine,
nothing in the environment should choose the code that runs, and no path the
daemon writes should be redirectable by something that got there first.
