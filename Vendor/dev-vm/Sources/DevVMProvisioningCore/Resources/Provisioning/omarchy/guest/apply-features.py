#!/usr/bin/env python3
"""Idempotent Omarchy feature operations used by the tagged Ansible roles."""

import argparse
import hashlib
import json
import os
import platform
import pwd
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parent))

from feature_contract import (
    CATALOGUE, FEATURES, FeatureError, requirements, selection, tools, validate_config,
)

BROWSERS = CATALOGUE["features"]["browsers"]["choices"]
AGENTS = set(CATALOGUE["features"]["agents"]["choices"])
CREDENTIALS = set(CATALOGUE["features"]["credentials"]["choices"])
DOCKER_PACKAGES = tuple(CATALOGUE["features"]["docker"]["packages"])
WORKSTATION_PACKAGES = tuple(CATALOGUE["workstation_packages"])
LANGUAGE_PACKAGES = CATALOGUE["language_packages"]
SHELL_PATHS = CATALOGUE["features"]["workstation"]["shells"]
SHELLS_FILE = Path("/etc/shells")
ZSH_STARTUP = {
    ".zshenv": ("Omarchy environment", "[ -r /usr/share/omarchy/default/bash/env-bootstrap ] && "
                ". /usr/share/omarchy/default/bash/env-bootstrap"),
    ".zshrc": ("mise activation", "if command -v mise >/dev/null 2>&1; then\n"
               '  eval "$(mise activate zsh)"\nfi'),
}
OH_MY_ZSH_STARTUP = ('export ZSH="$HOME/.oh-my-zsh"\n{theme}\n'
                     'if (( ! ${{+plugins}} )); then plugins=(git); fi\n'
                     'source "$ZSH/oh-my-zsh.sh"')
OH_MY_ZSH_THEMES = ('ZSH_THEME=""', 'ZSH_THEME="${ZSH_THEME-robbyrussell}"')
STARSHIP_STARTUP = ('if command -v starship >/dev/null 2>&1; then\n'
                    '  eval "$(starship init zsh)"\nfi')
STARSHIP_CONFIG = Path(".config/dev-vm/starship.toml")
CONTENT_HASH = "# dev-vm content-sha256: "


def tracked_content(text):
    return CONTENT_HASH + hashlib.sha256(text.encode()).hexdigest() + "\n" + text


def unchanged_content(text):
    header, _, content = text.partition("\n")
    return header == CONTENT_HASH + hashlib.sha256(content.encode()).hexdigest()


def managed_block(label, snippet, *, tracked=False):
    if tracked:
        snippet = tracked_content(snippet)
    return f"# >>> dev-vm {label} >>>\n{snippet}\n# <<< dev-vm {label} <<<\n"


def remove_managed_block(text, label, snippets):
    """Only replace blocks whose entire contents are still repository-owned."""
    start, end = f"# >>> dev-vm {label} >>>", f"# <<< dev-vm {label} <<<"
    if start not in text and end not in text:
        return text
    if text.count(start) == text.count(end) == 1:
        for snippet in snippets:
            block = managed_block(label, snippet)
            if block in text:
                return text.replace(block, "", 1)
        # Dynamic options can change between applications. A content digest
        # distinguishes our previous generated contents from personal edits.
        pattern = rf"(?m)^{re.escape(start)}\n(.*?)\n{re.escape(end)}\n"
        match = re.search(pattern, text, re.DOTALL)
        if match and unchanged_content(match[1]):
            return text[:match.start()] + text[match.end():]
    raise FeatureError("Preserving customized dev-vm block: " + label)


def run(argv, *, check=True):
    result = subprocess.run(
        [str(x) for x in argv], capture_output=True, text=True,
        cwd=Path.home(), env={**os.environ, "LC_ALL": "C.UTF-8"},
    )
    if check and result.returncode:
        raise FeatureError(f"{argv[0]} failed: {(result.stderr or result.stdout).strip()}")
    return result


def native(argv, *, check=True):
    return run(["bash", "-lc", shlex.join([str(x) for x in argv])], check=check)


class FeatureRunner:
    def __init__(self, feature, config, check=False, *, extension=False, defer_docker_access=False):
        self.feature = feature
        self.config = validate_config(feature, config, extension=extension)
        self.extension = extension
        self.defer_docker_access = defer_docker_access
        self.check = check
        self.actions = []
        self.notes = []

    def preflight(self):
        if platform.system() != "Linux" or platform.machine() != "aarch64" or os.geteuid() == 0:
            raise FeatureError("Run as the non-root owner of an Omarchy aarch64 guest")
        if native(["command", "-v", "omarchy"], check=False).returncode:
            raise FeatureError("Omarchy is required")
        if run(["pacman", "-Qq", "try-omarchy"], check=False).returncode:
            raise FeatureError("The native Try Omarchy integration package is required")
        if self.feature != "workstation" and not self.check:
            if run(["sudo", "-n", "true"], check=False).returncode:
                raise FeatureError("Enable Omarchy's native temporary sudo grant before applying features")

    def installed(self, package):
        result = run(["pacman", "-Qq", "--", package], check=False)
        if result.returncode not in (0, 1):
            raise FeatureError("Unable to inspect the guest package database")
        return result.returncode == 0

    def mutate(self, argv, description):
        self.actions.append(description)
        if not self.check:
            native(argv)

    def packages(self, packages):
        missing = [name for name in packages if not self.installed(name)]
        for name in missing:
            if run(["pacman", "-Si", "--", name], check=False).returncode:
                raise FeatureError(f"Package unavailable in configured ARM64 repositories: {name}; no repositories were added")
            tool = CATALOGUE["package_tools"].get(name)
            if tool and name != "python" and self.installed("mise-bin") and self.configured_tool(tool):
                raise FeatureError(f"Package {name} competes with an existing mise declaration for {tool}; select one provider explicitly")
        if missing:
            try:
                self.mutate(["omarchy-pkg-add", *missing], "Install packages: " + ", ".join(missing))
            except FeatureError as error:
                if "404" in str(error):
                    raise FeatureError(
                        f"{error}\nThe guest package database may reference expired archives. "
                        "Run 'omarchy update' in this guest, then retry. Feature application does not refresh databases or upgrade the guest."
                    ) from error
                raise
        return missing

    def browsers(self):
        for browser in self.config["browsers"]:
            if not self.installed(BROWSERS[browser]):
                self.mutate(["omarchy-install-browser", browser], "Install browser: " + browser)

    def docker(self):
        if not self.check:
            status = native(["sudo", "-n", "ufw", "status"]).stdout
            if not status.startswith("Status: active"):
                raise FeatureError("Docker requires the existing Omarchy UFW policy to be active; no policy was replaced")
        self.packages(DOCKER_PACKAGES)
        if self.check:
            self.actions.append("Verify Docker firewall integration with the native sudo grant")
            self.notes.append("Firewall repair is conservatively reported in check mode; no privileged writes run")
        else:
            paths = ("/etc/ufw/after.rules", "/etc/ufw/after6.rules", "/etc/ufw/user.rules", "/etc/ufw/user6.rules")
            before = native(["sudo", "-n", "sha256sum", *paths]).stdout
            native(["sudo", "-n", "ufw-docker", "install"])
            for subnet in ("172.16.0.0/12", "192.168.0.0/16"):
                native(["sudo", "-n", "ufw", "allow", "in", "proto", "udp", "from", subnet,
                        "to", "172.17.0.1", "port", "53", "comment", "allow-docker-dns"])
            after = native(["sudo", "-n", "sha256sum", *paths]).stdout
            if before != after:
                native(["sudo", "-n", "ufw", "reload"])
                self.actions.append("Configure native Docker firewall integration")
        enabled = not native(["systemctl", "is-enabled", "--quiet", "docker.socket"], check=False).returncode
        active = not native(["systemctl", "is-active", "--quiet", "docker.socket"], check=False).returncode
        service_active = not native(["systemctl", "is-active", "--quiet", "docker.service"], check=False).returncode
        if not service_active and (not enabled or not active):
            self.mutate(["sudo", "-n", "systemctl", "enable", "--now", "docker.socket"], "Enable Docker socket activation")
        if self.config["access"] == "sudoless":
            configured = native(["omarchy-sudo-docker", "--configured"], check=False)
            if configured.returncode not in (0, 1):
                raise FeatureError("Unable to inspect native Omarchy Docker access policy")
            if configured.returncode == 0:
                if self.check:
                    self.actions.append("Enable owner Docker access through Omarchy's native Sudoless Docker confirmation")
                elif not self.defer_docker_access:
                    raise FeatureError("Owner Docker access is missing. Run omarchy-setup-security-sudoless-docker interactively, then rerun; the supported launcher handles this consent step")
            if self.defer_docker_access:
                self.notes.append("The launcher must obtain native Docker consent and verify access from a fresh managed SSH session")
            elif not self.check:
                self.verify_docker_access(sudoless=True)
            elif configured.returncode == 1 and not native(["omarchy-sudo-docker"], check=False).returncode:
                self.notes.append("Docker group is configured but this session is stale; reboot through VM Manager before running project scripts")
        elif not self.check:
            self.verify_docker_access(sudoless=False)

    def verify_docker_access(self, *, sudoless):
        command = ["/usr/bin/docker", "--host", "unix:///var/run/docker.sock", "version", "--format", "{{.Server.Version}}"]
        if not sudoless:
            command = ["sudo", "-n", *command]
        result = native(["env", "-u", "DOCKER_HOST", "-u", "DOCKER_CONTEXT", *command], check=False)
        if result.returncode or not result.stdout.strip():
            raise FeatureError("Docker daemon access failed under the selected policy; a configured Docker group may require a fresh login or VM Manager restart. " + (result.stderr or result.stdout).strip())
        native(["/usr/bin/docker", "compose", "version"])
        native(["/usr/bin/docker", "buildx", "version"])
        self.notes.append("Docker daemon, Compose and Buildx verified " + ("without sudo" if sudoless else "through native sudo policy"))

    def configured_tool(self, tool):
        result = native(["mise", "ls", "--json", tool])
        try:
            value = json.loads(result.stdout)
        except ValueError as error:
            raise FeatureError("mise returned invalid tool metadata") from error
        if isinstance(value, dict):
            rows = value.get(tool, [])
        elif isinstance(value, list):
            # A tool-filtered `mise ls --json TOOL` returns an array whose
            # rows omit the tool name. Older/unfiltered output can name it.
            rows = value
        else:
            raise FeatureError("mise returned an unsupported tool metadata format")
        if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
            raise FeatureError("mise returned unsupported tool rows")
        return any(
            row.get("tool", row.get("name", tool)) == tool
            and (row.get("source") or row.get("requested_version") or row.get("active"))
            for row in rows
        )

    def toolchain(self, requested=None):
        requested = self.config["tools"] if requested is None else requested
        if not requested:
            return
        missing_mise = bool(self.packages(["mise-bin"]))
        if missing_mise:
            self.mutate(["mise", "reshim", "--system"], "Initialize Omarchy's lazy tool shims")
            self.mutate(["mise", "reshim"], "Initialize user tool shims")
        for tool, version in requested.items():
            if not self.check or not missing_mise:
                if native(["mise", "registry", tool], check=False).returncode:
                    raise FeatureError(f"Unknown mise registry short name: {tool}")
            if self.feature == "languages":
                self.packages(LANGUAGE_PACKAGES.get(tool, ()))
            selector = f"{tool}@{version}" if version else tool
            if self.check and missing_mise:
                self.actions.append("Install mise tool: " + selector)
                continue
            configured = self.configured_tool(tool)
            desired = native(["mise", "where", selector], check=False)
            current = native(["mise", "where", tool], check=False)
            if configured and desired.returncode == 0 and current.returncode == 0 and desired.stdout.strip() == current.stdout.strip():
                continue
            if version:
                self.mutate(["mise", "use", "--global", selector], "Select mise tool: " + selector)
            elif configured:
                self.mutate(["mise", "install", tool], "Install Omarchy's configured tool: " + tool)
            else:
                self.mutate(["mise", "use", "--global", tool + "@latest"], "Select user mise tool: " + tool)

    def project_toolchain(self):
        packages, _ = requirements(self.feature, self.config)
        missing_mise = not self.installed("mise-bin")
        self.packages(packages)
        if missing_mise:
            self.mutate(["mise", "reshim", "--system"], "Initialize Omarchy's lazy tool shims")
            self.mutate(["mise", "reshim"], "Initialize user tool shims")
        if self.check and missing_mise:
            self.notes.append("Native Bash activation will be verified after mise installation")
            return
        # Use the owner's existing interactive rc chain, from HOME, without
        # adding startup files, trusting projects or installing declared tools.
        result = native(["bash", "-ic", 'declare -F mise >/dev/null && [[ "${PROMPT_COMMAND[*]}" == *mise* ]]'], check=False)
        if result.returncode:
            raise FeatureError("Omarchy's native Bash mise activation is missing; restore the native shell integration before retrying. No shell configuration was replaced")
        self.notes.append("Native Bash mise activation verified; project tools remain project-managed")
        if os.path.realpath(pwd.getpwuid(os.geteuid()).pw_shell) == os.path.realpath(SHELL_PATHS["zsh"]):
            self.verify_zsh_activation()

    def verify_zsh_activation(self):
        probe = ('[[ "$MISE_SHELL" == zsh ]] && (( $+functions[mise] )) && '
                 '(( ${precmd_functions[(I)*mise*]} > 0 )) && '
                 '(( ${chpwd_functions[(I)*mise*]} > 0 ))')
        if native(["env", "DISABLE_AUTO_UPDATE=true", "zsh", "-ic", probe], check=False).returncode:
            raise FeatureError("Zsh mise activation is missing; select workstation shell zsh or restore ~/.zshrc before retrying")
        self.notes.append("Zsh mise activation verified; no global runtime selections added")

    def zsh_startup(self):
        edits = []
        for name, (label, snippet) in ZSH_STARTUP.items():
            path = Path.home() / name
            if path.is_symlink() or (path.exists() and not path.is_file()):
                raise FeatureError(f"Preserving non-regular zsh startup file: {name}; configure it explicitly or select shell keep")
            existing = path.read_text() if path.exists() else ""
            updated = existing
            # Validate existing managed blocks, but also reuse the original
            # unmarked native activation installed by earlier workstation setups.
            without = remove_managed_block(existing, label, [snippet])
            if without == existing and snippet not in existing and not (name == ".zshrc" and "mise activate zsh" in existing):
                updated += ("\n" if updated and not updated.endswith("\n") else "") + managed_block(label, snippet)
            if name == ".zshrc":
                variants = [OH_MY_ZSH_STARTUP.format(theme=theme) for theme in OH_MY_ZSH_THEMES]
                updated = remove_managed_block(updated, "Oh My Zsh", variants)
                updated = remove_managed_block(updated, "Starship prompt", [STARSHIP_STARTUP])
                personal = "\n".join(line for line in updated.splitlines() if not line.lstrip().startswith("#"))
                if self.config["oh_my_zsh"] and "oh-my-zsh.sh" in personal:
                    raise FeatureError("Preserving user-managed Oh My Zsh initialization; set oh_my_zsh false or migrate it before retrying")
                if self.config["starship"] and re.search(r"starship\s+init|powerlevel10k|p10k\.zsh", personal):
                    raise FeatureError("Preserving user-managed prompt initialization; set starship false or migrate it before retrying")
                blocks = []
                if self.config["oh_my_zsh"]:
                    theme = OH_MY_ZSH_THEMES[0 if self.config["starship"] else 1]
                    plugins = self.config["oh_my_zsh_plugins"]
                    plugin_init = ('if (( ! ${+plugins} )); then plugins=(git); fi' if plugins is None else
                                   "plugins=(" + shlex.join(plugins) + ")")
                    update = self.config["oh_my_zsh_update_mode"]
                    settings = [theme, plugin_init]
                    if update:
                        settings.append("zstyle ':omz:update' mode " + update)
                    snippet = 'export ZSH="$HOME/.oh-my-zsh"\n' + "\n".join(settings) + '\nsource "$ZSH/oh-my-zsh.sh"'
                    blocks.append(managed_block("Oh My Zsh", snippet, tracked=True))
                if self.config["starship"]:
                    snippet = STARSHIP_STARTUP
                    if self.config["starship_config"]:
                        snippet = 'export STARSHIP_CONFIG="$HOME/' + str(STARSHIP_CONFIG) + '"\n' + snippet
                    blocks.append(managed_block("Starship prompt", snippet, tracked=True))
                if blocks:
                    updated += ("\n" if updated and not updated.endswith("\n") else "") + "".join(blocks)
            if updated != existing:
                edits.append((path, updated))
        return edits

    def starship_configuration(self):
        if not self.config["starship"] or not self.config["starship_config"]:
            return []
        path = Path.home() / STARSHIP_CONFIG
        for parent in (path.parent.parent, path.parent):
            if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
                raise FeatureError("Preserving non-directory or symlinked Starship configuration path: " + str(parent))
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise FeatureError("Preserving non-regular managed Starship configuration")
        existing = path.read_text() if path.exists() else None
        if existing is not None and not unchanged_content(existing):
            raise FeatureError("Preserving customized managed Starship configuration; migrate edits into starship_config first")
        desired = tracked_content(self.config["starship_config"])
        return [(path, desired)] if existing != desired else []

    def verify_oh_my_zsh_plugins(self, path):
        plugins = self.config["oh_my_zsh_plugins"]
        if plugins is None:
            return
        if not path.exists() and self.check:
            self.notes.append("Selected Oh My Zsh plugin availability will be verified after cloning; no startup files changed")
            return
        for plugin in plugins:
            if not any((base / plugin / name).is_file()
                       for base in (path / "plugins", path / "custom/plugins")
                       for name in (plugin + ".plugin.zsh", "_" + plugin)):
                raise FeatureError("Oh My Zsh plugin unavailable: " + plugin + "; use an installed bundled/default-custom plugin. No startup files changed")

    def oh_my_zsh(self):
        if not self.config["oh_my_zsh"]:
            return
        path = Path.home() / ".oh-my-zsh"
        if path.exists() or path.is_symlink():
            if not path.is_dir() or not (path / "oh-my-zsh.sh").is_file():
                raise FeatureError("Preserving incomplete or non-directory ~/.oh-my-zsh; move it aside explicitly before retrying")
            self.verify_oh_my_zsh_plugins(path)
            self.notes.append("Existing Oh My Zsh installation reused; updates remain owned by omz update")
            return
        self.actions.append("Install Oh My Zsh from official upstream into ~/.oh-my-zsh")
        if not self.check:
            # Clone as the owner, without running upstream's rc-replacing installer.
            # Stage first so an interrupted download cannot claim the final path.
            with tempfile.TemporaryDirectory(prefix=".dev-vm-omz-", dir=Path.home()) as folder:
                staged = Path(folder) / "oh-my-zsh"
                native(["env", "GIT_TERMINAL_PROMPT=0", "GIT_ASKPASS=/bin/false", "git", "-c", "credential.helper=",
                        "clone", "--depth", "1", "--", CATALOGUE["features"]["workstation"]["oh_my_zsh_repository"], str(staged)])
                if not (staged / "oh-my-zsh.sh").is_file():
                    raise FeatureError("Official Oh My Zsh clone is missing its startup script")
                self.verify_oh_my_zsh_plugins(staged)
                staged.rename(path)
        else:
            self.verify_oh_my_zsh_plugins(path)

    def login_shell(self):
        selected = self.config["shell"]
        if selected == "keep":
            return
        account = pwd.getpwuid(os.geteuid())
        desired = SHELL_PATHS[selected]
        edits = self.starship_configuration() + self.zsh_startup() if selected == "zsh" else []
        packages, _ = requirements("workstation", self.config)
        self.packages(packages)
        if selected == "zsh":
            self.oh_my_zsh()
        for path, updated in edits:
            self.actions.append(("Configure Starship: " if path.name == "starship.toml" else "Configure zsh startup: ") + path.name)
            if not self.check:
                # Preserve personal configuration and the existing file mode.
                new_file = not path.exists()
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(updated)
                if new_file:
                    path.chmod(0o600)
        if not self.check:
            allowed = {line.split("#", 1)[0].strip() for line in SHELLS_FILE.read_text().splitlines()}
            if desired not in allowed or native(["test", "-x", desired], check=False).returncode:
                raise FeatureError("Selected login shell is not executable and registered in /etc/shells: " + desired)
            if selected == "zsh":
                for name in ZSH_STARTUP:
                    native(["zsh", "-n", str(Path.home() / name)])
                if native(["env", "DISABLE_AUTO_UPDATE=true", "zsh", "-ic", '[[ -n "$OMARCHY_PATH" ]] && command -v omarchy >/dev/null'], check=False).returncode:
                    raise FeatureError("Zsh cannot load Omarchy's native environment; login shell was not changed")
                if self.installed("mise-bin"):
                    self.verify_zsh_activation()
                probes = []
                if self.config["oh_my_zsh"]:
                    probes.append('(( $+functions[omz] ))')
                if self.config["starship"]:
                    probes.append('[[ "$STARSHIP_SHELL" == zsh ]] && (( ${precmd_functions[(I)*starship*]} > 0 ))')
                if probes and native(["env", "DISABLE_AUTO_UPDATE=true", "zsh", "-ic", " && ".join(probes)], check=False).returncode:
                    raise FeatureError("Selected Oh My Zsh/Starship startup integration is missing; login shell was not changed")

        if os.path.realpath(account.pw_shell) != os.path.realpath(desired):
            self.mutate(["sudo", "-n", "chsh", "-s", desired, "--", account.pw_name], "Set owner login shell: " + selected)
            if not self.check and os.path.realpath(pwd.getpwuid(os.geteuid()).pw_shell) != os.path.realpath(desired):
                raise FeatureError("The owner's login shell did not change to " + desired)
            self.notes.append("Existing terminals keep their shell; log out and back in to refresh the desktop session")

    def snapshot(self):
        home = Path.home()
        paths = (
            ".config/foot/foot.ini", ".config/omarchy/shell.json", ".config/hypr/hyprland.lua",
            ".config/hypr/looknfeel.lua", ".config/hypr/dev-workstation-layout.lua",
            ".config/systemd/user/omarchy-sleep-lock.service",
            ".config/systemd/user/dev-workstation-first-login.service.d/90-session-order.conf",
            ".local/state/omarchy/current/theme.name", ".local/state/omarchy/current/theme",
        )
        result = {}
        for name in paths:
            path = home / name
            if path.is_symlink():
                result[name] = ("link", os.readlink(path))
            elif path.is_file():
                result[name] = ("file", hashlib.sha256(path.read_bytes()).hexdigest())
        return result

    def first_login_ordering(self, unit=Path("/usr/lib/systemd/user/dev-workstation-first-login.service")):
        # Repair only the exact repository unit shipped by preferences 1-1.
        if not unit.is_file() or hashlib.sha256(unit.read_bytes()).hexdigest() != "2184718491edc880ff5256728419d97a4640d762da30dd4e2cfa1030f13f48aa":
            return
        path = Path.home() / ".config/systemd/user/dev-workstation-first-login.service.d/90-session-order.conf"
        content = "[Unit]\nAfter=graphical-session.target try-omarchy-session.service\n"
        if path.is_symlink() or (path.exists() and path.read_text() != content):
            raise FeatureError("Preserving a customized first-login ordering override")
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
            path.chmod(0o644)
            native(["systemctl", "--user", "daemon-reload"])

    def workstation(self):
        payload = Path(__file__).resolve().parent
        layout = self.config["layout"]
        if layout and (Path(layout).resolve().parent != payload or not Path(layout).is_file()):
            raise FeatureError("Layout must be the explicitly staged payload file")
        self.packages(WORKSTATION_PACKAGES)
        self.login_shell()
        if self.check:
            self.actions.append("Compare/apply the selected workstation preferences and GPU compatibility repair")
            self.notes.append("Workstation check mode reports conservatively and executes no configuration scripts")
            return
        before = self.snapshot()
        self.first_login_ordering()
        command = ["bash", str(payload / "apply-workstation.sh"), "--foot-font-size", str(self.config["font_size"]),
                   "--idle-mode", self.config["idle_mode"]]
        if self.config["theme"]:
            command += ["--theme-url", self.config["theme"]]
        if layout:
            command += ["--layout-file", layout]
        elif self.config["remove_layout"]:
            command += ["--remove-layout"]
        native(command)
        native(["bash", str(payload / "repair-try-omarchy-black-screen.sh")])
        if before != self.snapshot():
            self.actions.append("Apply workstation preferences")

    def apply(self):
        self.preflight()
        handler = "tools" if self.extension else CATALOGUE["features"][self.feature]["handler"]
        if handler == "tools":
            self.packages(self.config["packages"])
            self.toolchain()
        elif handler == "selection":
            definition = CATALOGUE["features"][self.feature]
            self.packages([definition["choices"][item] for item in self.config[definition["option"]]])
        elif handler in ("agents", "languages"):
            self.toolchain()
        elif handler == "toolchain":
            self.project_toolchain()
        elif handler == "keyring":
            self.packages(requirements(self.feature, self.config)[0])
        elif self.feature == "credentials":
            packages = list(self.config["packages"])
            # Preserve the legacy package choice, reusing Omarchy's declared CLI
            # when it would otherwise compete with a newly installed package.
            if ("github-cli" in packages and not self.installed("github-cli")
                    and self.installed("mise-bin") and self.configured_tool("gh")):
                packages.remove("github-cli")
                self.toolchain({"gh": ""})
            self.packages(packages)
        else:
            getattr(self, self.feature)()
        return {"changed": bool(self.actions), "actions": self.actions, "notes": self.notes,
                "check_mode": self.check, "feature": self.feature}


def preflight_plan(value, *, check=False):
    """Check all missing repository packages before any selected role mutates."""
    if not isinstance(value, list):
        raise FeatureError("Preflight plan must be a list of feature operations")
    requested_packages, requested_tools = {}, {}
    for item in value:
        if not isinstance(item, dict) or set(item) != {"feature", "config", "extension"} or type(item["extension"]) is not bool:
            raise FeatureError("Invalid preflight operation")
        runner = FeatureRunner(item["feature"], item["config"], check, extension=item["extension"])
        runner.preflight()
        packages, tool_versions = requirements(item["feature"], item["config"], extension=item["extension"])
        for package in packages:
            requested_packages.setdefault(package, set()).add(item["feature"])
        for tool, selector in tool_versions.items():
            if tool in requested_tools and requested_tools[tool] != selector:
                raise FeatureError(f"Conflicting mise tool selections: {tool}")
            requested_tools[tool] = selector
    if not value:
        return
    for package in sorted(requested_packages):
        tool = CATALOGUE["package_tools"].get(package)
        if tool in requested_tools:
            raise FeatureError(f"Competing package/mise providers: {package} and {tool}")
        if (tool and package != "python" and not runner.installed(package) and runner.installed("mise-bin")
                and runner.configured_tool(tool)):
            credential_alias = package == "github-cli" and requested_packages[package] == {"credentials"}
            if not credential_alias:
                raise FeatureError(f"Package {package} competes with an existing mise declaration for {tool}")
            requested_tools.setdefault(tool, "")
            continue
        if not runner.installed(package) and run(["pacman", "-Si", "--", package], check=False).returncode:
            raise FeatureError(f"Package unavailable in configured ARM64 repositories: {package}")
    if not check and any(item["feature"] == "docker" for item in value):
        if not native(["sudo", "-n", "ufw", "status"]).stdout.startswith("Status: active"):
            raise FeatureError("Docker requires the existing Omarchy UFW policy to be active; no policy was replaced")
    if requested_tools and runner.installed("mise-bin"):
        for tool in requested_tools:
            if native(["mise", "registry", tool], check=False).returncode:
                raise FeatureError(f"Unknown mise registry short name: {tool}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feature")
    parser.add_argument("--extension", action="store_true")
    parser.add_argument("--preflight-plan", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--defer-docker-access", action="store_true", help="Launcher-only: verify Docker access after native interactive consent")
    args = parser.parse_args()
    runner = None
    try:
        config = json.load(sys.stdin)
        if args.preflight_plan:
            preflight_plan(config, check=args.check)
            print(json.dumps({"changed": False, "preflight": True}))
            return 0
        if args.defer_docker_access and args.feature != "docker":
            raise FeatureError("Docker access deferral applies only to the Docker feature")
        runner = FeatureRunner(args.feature, config, args.check, extension=args.extension,
                               defer_docker_access=args.defer_docker_access)
        print(json.dumps(runner.apply()))
    except (OSError, ValueError, FeatureError) as error:
        print(json.dumps({"changed": bool(runner and runner.actions), "actions": runner.actions if runner else []}))
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
