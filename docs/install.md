# Installing Open-Breach apps on Linux

Open-Breach apps come as native packages from Open-Breach's own apt and dnf repositories. You add the repository once; after that the apps install, update and uninstall with the tools your system already has.

The examples install Rick, the file manager. Any other package name works the same way.

## The one-line way

```sh
curl -fsSL https://get.openbreach.dev/install.sh | sh -s rick
```

On a system without curl, wget does the same:

```sh
wget -qO- https://get.openbreach.dev/install.sh | sh -s rick
```

The script reads `/etc/os-release`, adds the Open-Breach repository for your distro together with its signing key, and installs the package with `apt` or `dnf`. It asks for `sudo` when it is not run as root. It does nothing else, and it is short enough to read first: [`install.sh`](../install.sh).

To see what it would do without changing anything:

```sh
curl -fsSL https://get.openbreach.dev/install.sh | sh -s -- --dry-run rick
```

## Which distros

Packages are built for these distro releases, for x86-64 and arm64:

| Distro | Repository | Format |
| --- | --- | --- |
| Debian 13 | `debian-13` | deb |
| Debian 12 | `debian-12` | deb |
| Ubuntu 26.04 LTS | `ubuntu-26.04` | deb |
| Ubuntu 24.04 LTS | `ubuntu-24.04` | deb |
| Fedora 45 | `fedora-45` | rpm |
| Fedora 44 | `fedora-44` | rpm |

The list follows a rule: the two newest Fedora releases, Debian stable and oldstable, and the two latest Ubuntu LTS releases. When a distro ships a new release it joins the list, and the release the rule no longer covers gets no further updates from here.

A distro that is based on one of them takes that one's packages:

| Your distro | Uses the packages for |
| --- | --- |
| Linux Mint 22 | Ubuntu 24.04 |
| Pop!_OS 24.04 | Ubuntu 24.04 |
| Zorin OS 18 | Ubuntu 24.04 |
| elementary OS 8 | Ubuntu 24.04 |
| KDE neon (on Ubuntu 24.04) | Ubuntu 24.04 |
| LMDE 7 | Debian 13 |
| LMDE 6 | Debian 12 |
| Nobara 44 | Fedora 44 |
| Ultramarine 44 | Fedora 44 |

A release of one of these that moves to a newer base takes that base's packages, as long as the base is in the first table: one built on Ubuntu 26.04 takes the Ubuntu 26.04 packages, one that follows Fedora 45 the Fedora 45 packages.

The install script works this out by itself. By hand, pick the row of the distro yours is based on.

The arm64 packages are built and installed on arm64 machines by the build, and are otherwise untested. If you run one, tell us how it goes in the app's issues.

Not covered here: Arch and its derivatives get the apps from the AUR, and NixOS builds them from each app's flake.

## By hand

The same steps the script takes.

### Debian, Ubuntu and their derivatives

Put the signing key where apt keeps the keys of third-party repositories:

```sh
sudo install -d -m 755 /etc/apt/keyrings
curl -fsSL https://get.openbreach.dev/keys/openbreach.gpg | sudo tee /etc/apt/keyrings/openbreach.gpg > /dev/null
```

Add the repository. The line names the repository of your distro from the table above, `ubuntu-26.04` here:

```sh
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/openbreach.gpg] https://get.openbreach.dev/apt ubuntu-26.04 main" | sudo tee /etc/apt/sources.list.d/openbreach.list
```

For another release, its name goes in place of `ubuntu-26.04`: `ubuntu-24.04`, `debian-13` or `debian-12`.

Install:

```sh
sudo apt update
sudo apt install rick
```

### Fedora and its derivatives

Add the repository:

```sh
sudo tee /etc/yum.repos.d/openbreach.repo << 'EOF'
[openbreach]
name=Open-Breach
baseurl=https://get.openbreach.dev/rpm/fedora-$releasever/$basearch
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=https://get.openbreach.dev/keys/openbreach.asc
EOF
```

`$releasever` and `$basearch` are left as they are: dnf fills in your Fedora release and your machine's architecture.

Install:

```sh
sudo dnf install rick
```

The first time, dnf shows the key and asks whether to import it. Its fingerprint is [below](#what-the-key-signs).

## What the key signs

Every index of the repositories is signed with the Open-Breach key, and the index lists the checksum of every package. apt checks that signature because of `signed-by=`, dnf because of `repo_gpgcheck=1`. The packages are not signed one by one, which is why the dnf repository has `gpgcheck=0`: with `repo_gpgcheck=1`, a package that is not the one the signed index lists is still refused.

The key is `Open-Breach Packages <packages@openbreach.dev>`, with this fingerprint:

```
4EBA 5A09 2189 11BE B9E2 06E0 2A5A 0A8C E695 300A
```

To check the key you downloaded against it:

```sh
gpg --show-keys --with-fingerprint /etc/apt/keyrings/openbreach.gpg
```

```sh
curl -fsSL https://get.openbreach.dev/keys/openbreach.asc | gpg --show-keys --with-fingerprint
```

The first is for apt, after the key is in place; the second works anywhere, and before you add the dnf repository.

The public key is in this repository under [`keys/`](../keys/), and is served as `https://get.openbreach.dev/keys/openbreach.gpg` for apt and, in text form, as `https://get.openbreach.dev/keys/openbreach.asc` for dnf. How the packages are built, signed and published is all in this repository: [`linux-packages.md`](linux-packages.md) and [`repositories.md`](repositories.md).

## Where a package was built

The key above signs the repositories. A second record, separate from it, says where a single file was built: every package and tarball of an app in a public repository carries a GitHub build attestation. It is signed by GitHub and names the workflow, the repository and the commit the file was built from. Nobody holds a key for it.

To check a package or a tarball you downloaded from an app's release, with the [GitHub CLI](https://cli.github.com):

```sh
gh attestation verify rick_1.2.3_ubuntu-24.04_amd64.deb --owner Open-Breach --signer-repo Open-Breach/trebuchet
```

`--signer-repo` names this repository because its workflow builds the packages, for whichever app. The command fails for a file that was changed after it was built, and for one that was built anywhere else. An attestation says where a file comes from, not that it is safe.

## Plugins

An app with plugins has the ones every install needs inside its own package. The others are packages of their own, named `<app>-plugin-<id>`, and install like any package once the repository is added:

```sh
sudo apt install rick-plugin-git
sudo dnf install rick-plugin-git
```

The one-liner takes the same name, and brings the app with the plugin:

```sh
curl -fsSL https://get.openbreach.dev/install.sh | sh -s rick-plugin-git
```

`rick-plugins` is all of Rick's plugins in one name. `apt search rick-plugin` and `dnf search rick-plugin` list them.

A plugin is built together with one version of its app and fits no other, so each plugin package asks for the app in exactly its own version. You do not have to think about it: installing a plugin installs the app that matches, an upgrade moves the two together, and the package manager refuses a combination that would not work.

A Rick from a package gets its plugins this way, not from the plugin list inside Rick: there Rick shows the command above and downloads nothing.

## Updating, going back, removing

Updates arrive with the rest of your system: `sudo apt upgrade`, `sudo dnf upgrade`, or your desktop's software updater. An app's plugin packages are updated with it.

The repositories keep the last three versions of every package, so you can go back to an earlier one. Name the plugin packages you have with the app, since each goes with one version of it:

```sh
sudo apt install rick=1.2.2
sudo dnf downgrade rick-1.2.2
```

```sh
sudo apt install rick=1.2.2 rick-plugin-git=1.2.2
sudo dnf downgrade rick-1.2.2 rick-plugin-git-1.2.2
```

To remove an app, and the repository if you no longer want it:

```sh
sudo apt remove rick
sudo rm /etc/apt/sources.list.d/openbreach.list /etc/apt/keyrings/openbreach.gpg
```

```sh
sudo dnf remove rick
sudo rm /etc/yum.repos.d/openbreach.repo
```

## Without a repository

Every release on an app's GitHub Releases page also carries the packages themselves and a tarball per architecture, such as `rick-1.2.3-linux-x64.tar.gz`. A package installed from a downloaded file does not update itself.
