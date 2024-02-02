# shellcheck disable=SC2034

NAME="dotsh"
CODENAME="dotsh"
AUTHORS=("AXON <axonasif@gmail.com>")
VERSION="1.0"
DEPENDENCIES=(
	std::85df7f3
  https://github.com/bashbox/libtmux::2863b38
  https://github.com/axonasif/bashenv_zsh::c56d334
)
REPOSITORY="https://github.com/axonasif/dotsh.git"
BASHBOX_COMPAT="0.3.9~"

bashbox::build::after() {
	local root_script="$_arg_path/$CODENAME";
	cp "$_target_workfile" "$root_script";
	chmod +x "$root_script";
}

bashbox::build::before() {
	# TODO: Port to std
	local git_dir="$_arg_path/.git";
	local hooks_dir="$git_dir/hooks";
	local pre_commit_hook="$hooks_dir/pre-commit";
	if test -e "$git_dir" && test ! -e "$pre_commit_hook"; then {
		log::info "Setting up pre-commit git hook";
		mkdir -p "$hooks_dir";
		printf '%s\n' \
					'#!/usr/bin/env sh' \
					'bashbox build --release' \
					'git add dotsh' > "$pre_commit_hook";
		chmod +x "$pre_commit_hook";
	} fi
}

function livetest {

  function docker() {
    DOCKER_BUILDKIT=1 command docker "$@";
  }

	case "${1:-}" in
		"minimg")
			CONTAINER_IMAGE="axonasif/dotfiles-testing-min:latest";
		;;
		"ws")
			trim_leading_trailing() {
				local _stream="${1:-}";
				local _stdin;
				if test -z "${_stream}"; then {
					read -r _stdin;
					_stream="$_stdin";
				} fi

				# remove leading whitespace characters
				_stream="${_stream#"${_stream%%[![:space:]]*}"}"
				# remove trailing whitespace characters
				_stream="${_stream%"${_stream##*[![:space:]]}"}"
				printf '%s\n' "$_stream"
			}
			export DOTFILES_READ_GITPOD_YML=true;
			declare default_gitpod_image="gitpod/workspace-full:latest";
			declare CONTAINER_IMAGE="$default_gitpod_image";
			declare gitpod_yml=("${GITPOD_REPO_ROOT:-}/".gitpod.y*ml);

			if test -e "${gitpod_yml:-}"; then {
				gitpod_yml_path="${gitpod_yml[0]}";

				if ! yq -o=yaml -reM '""' 1>/dev/null; then {
					log::error "Syntax errors were found on $gitpod_yml_path" 1 || exit;
				} fi

				# Get image source
				if res="$(yq -o=yaml -I0 -erM '.image' "$gitpod_yml_path" 2>/dev/null)"; then {
					if [[ "$res" == file:* ]]; then {
						res="${res##*:}" && res="$(trim_leading_trailing "$res")"; # Trim file: and extra spaces
						declare custom_dockerfile="$GITPOD_REPO_ROOT/$res";
						if test ! -e "$custom_dockerfile"; then {
							log::error "Your custom dockerfile ${BGREEN}$res${RC} doesn't exist at $GITPOD_REPO_ROOT" 1 || exit;
						} fi

						declare local_container_image_name="workspace-image";
						docker build -t "$local_container_image_name" -f "$custom_dockerfile" "$GITPOD_REPO_ROOT";

						CONTAINER_IMAGE="$local_container_image_name";

					} else {
						CONTAINER_IMAGE="$(trim_leading_trailing "$res")";
					} fi
				} fi
			} fi

			if [[ "$CONTAINER_IMAGE" == *\ * ]]; then {
				log::error "$gitpod_yml_path:image contains illegal spaces" 1 || exit;
			} fi
		;;
		"stress")
			export DOTFILES_STRESS_TEST=true;
			while livetest; do continue; done
		;;
	esac
	
	function mount::unloadroot() {
		local root="$1";
		local _mountpoint;
		while read -r _mountpoint; do
			sudo umount "$_mountpoint";
		done < <(mount | grep "$root" | awk '{print $3}' | sort -r || true);
	}

	function mount::overlay() {
		local namespace="$1";
		local lowerdir="$2";
		local overlay_root="/tmp/.gitpod_overlay/${namespace}";
		local upperdir="${overlay_root}/up";
		local workdir="${overlay_root}/work";
		local mountdir="${overlay_root}/mount";

		mount::unloadroot "$overlay_root";
		sudo rm -rf "$overlay_root";
		mkdir -p "$overlay_root"/{up,work,mount};

		sudo mount -t overlay overlay \
			-o lowerdir="${lowerdir}",upperdir="${upperdir}",workdir="${workdir}" "${mountdir}";

		# Return mount dir
		printf '%s\n' "${mountdir}";
	}

	declare CONTAINER_IMAGE="${CONTAINER_IMAGE:-"axonasif/dotfiles-testing-full:latest"}"; # From src/dockerfiles/testing-full.Dockerfile

	log::info "Running bashbox build --release";
	subcommand::build --release;
	source "$_target_workdir/utils/common.sh";

	local duplicate_workspace_root="$(mount::overlay ws /workspace)";
	# local workspace_sources;

	# if test -n "${GITPOD_REPO_ROOTS:-}"; then {
	# 	local repo_roots;
	# 	IFS=',' read -ra workspace_sources <<<"$GITPOD_REPO_ROOTS";
	# } else {
	# 	workspace_sources=("${_arg_path}");
	# } fi
	# if test -e /workspace/.gitpod; then {
	# 	workspace_sources+=("/workspace/.gitpod");
	# } fi

	# log::info "Creating a clone of ${workspace_sources} at $duplicate_workspace_root" && {
	# 	if command::exists rsync; then {
	# 		mkdir -p "$duplicate_workspace_root";
	# 		rsync -ah --info=progress2 --delete "${workspace_sources[@]}" "$duplicate_workspace_root";
	# 	} else {
	# 		rm -rf "$duplicate_workspace_root";
	# 		mkdir -p "$duplicate_workspace_root";
	# 		cp -ra "${workspace_sources[@]}" "$duplicate_workspace_root";
	# 	} fi
	# }

	local ide_mirror="/tmp/.idem";
	if test ! -e "$ide_mirror" && test -e /ide; then {
		log::info "Creating /ide mirror";
		cp -ra /ide "$ide_mirror";
	} fi
	## local ide_cmd ide_port;
	## ide_cmd="$(ps -p $(pgrep -f 'sh /ide/bin/gitpod-code' | head -n1) -o args --no-headers)";
	## ide_port="33000";
	## ide_cmd="${ide_cmd//23000/${ide_port}} >/ide/server_log 2>&1";

	log::info "Starting a fake Gitpod workspace with headless IDE";

	local docker_args=();
	docker_args+=(
		run
		# --rm
		--net=host
	)
	docker_args+=(
		# Shared mountpoints
		-v "$duplicate_workspace_root:/workspace"
		-v "$_arg_path:$HOME/.dotfiles"
	)

	if is::gitpod; then {
		docker_args+=(
			# IDE mountpoints
			-v "$ide_mirror:/ide"
			-v /usr/bin/gp:/usr/bin/gp:ro
			# Gitpod specific
			-v /.supervisor:/.supervisor
			# Required for rclone
			--privileged
			--device /dev/fuse
			# Docker socket
			-v /var/run/docker.sock:/var/run/docker.sock
			# Add IDE bindir to PATH
		)
	} fi
	
	# local dotfiles_repos_dir="$HOME/.dotfiles-sh";
	# if test -e "$dotfiles_repos_dir"; then {
	# 	docker_args+=(
	# 		-v "$dotfiles_repos_dir:$dotfiles_repos_dir"
	# 	)
	# } fi

	if is::gitpod; then {
		# Pass on local environment variables

		declare gitpod_env_vars="${!GITPOD_*}" && {
			gitpod_env_vars="${gitpod_env_vars//"GITPOD_TASKS"/}";
		}
		declare gp_env_vars="${!GP_*}" && {
			declare key && for key in GP_PYENV_FAKEROOT GP_PYENV_INIT GP_PYENV_MIRROR; do {
				gp_env_vars="${gp_env_vars//"${key}"/}";
			} done
		}

		for key in ${gitpod_env_vars:-} ${gp_env_vars:-}; do {
			docker_args+=(-e "${key}");
		} done
		docker_args+=(
			# Fake gitpod tasks for testing
			-e GITPOD_TASKS='[{"name":"Test foo","command":"echo This is fooooo; exit 2"},{"name":"Test boo", "command":"echo This is boooo"}]'

			# !! Note: the DOTFILES_ env vars could be overwritten by https://gitpod.io/variables even if you set them here.
			# Disable ssh:// protocol launch
			-e DOTFILES_SPAWN_SSH_PROTO=false
			## These options below are also available, see variables.sh for more info
			# -e DOTFILES_SHELL=zsh
			-e DOTFILES_TMUX=true
			# -e DOTFILES_EDITOR=emacs

			# The below two are only set conditionally
			-e DOTFILES_READ_GITPOD_YML
			-e DOTFILES_STRESS_TEST
		)
	} fi

	docker_args+=(
		# Container image
		-it "$CONTAINER_IMAGE"
	)

	function startup_command() {
		export PATH="$HOME/.nix-profile/bin:/ide/bin/remote-cli:$PATH";
		local logfile="$HOME/.dotfiles.log";
		# local tail_cmd="less -S -XR +F $logfile";
		local tail_cmd="tail -n +0 -F $logfile";
		# Load https://gitpod.io/variables into environment
		eval "$(gp env -e)";
		# Spawn the log pager
		$tail_cmd 2>/dev/null & disown;

		set +m; # Temporarily disable job control
		{ "$HOME/.dotfiles/install.sh" 2>&1; } >"$logfile" 2>&1 & wait;
		set -m;

		(
			until tmux has-session 2>/dev/null; do sleep 1; done;
			pkill -9 -f "${tail_cmd//+/\\+}" || :;
			tmux new-window -n ".dotfiles.log" "$tail_cmd"\; setw -g mouse on\; set -g visual-activity off;
			until test -n "$(tmux list-clients)"; do sleep 1; done;
			printf '====== %% %s\n' \
				"Run 'tmux detach' to exit from here" \
				"Press 'ctrl+c' to exit the log-pager" \
				"You can click between tabs/windows in the bottom" >> "$logfile";
			if test "${DOTFILES_STRESS_TEST:-}" == true; then {
				# tmux select-window -t :1;
				sleep 2;
				tmux detach-client;
			} fi
		) & disown;

		if test "${DOTFILES_TMUX:-true}" == true; then {
			AWAIT_SHIM_PRINT_INDICATOR=true exec tmux attach;
			# exec bash -li;
		} else {
			exec bash -li;
		} fi

		# Fallback
		if test $? != 0; then {
			printf '%s\n' "PS1='testing-dots \w \$ '" >> "$HOME/.bashrc";
			printf 'INFO: \n\n%s\n\n' "Falling back to debug bash shell";
			exec bash -li;
		} fi
	}

	# if is::gitpod; then {
		docker_args+=(
			# Startup command
			/bin/bash -li
		)
	# } else {
	# 	docker_args+=(
	# 		/bin/bash -li
	# 	)
	# } fi
	# local confirmed_statfile="/tmp/.confirmed_statfile";
	# touch "$confirmed_statfile";
	# local confirmed_times="$(( $(<"$confirmed_statfile") + 1 ))";
	# if [[ "$confirmed_times" -lt 2 ]]; then {
	# 	printf '\n';
	# 	printf 'INFO: %b\n' "Now this will boot into a simulated Gitpod workspace with shared host resources" \
	# 						"To detach from the tmux session, you can run ${BPURPLE}tmux detach${RC}"
	# 	printf '\n';
	# 	read -r -p ">>> Press Enter/return to continue execution";
	# 	printf '%s\n' "$confirmed_times" > "$confirmed_statfile";
	# } fi

	# local lckfile="/workspace/.dinit";
	# if test -e "$lckfile" && test ! -s "$lckfile"; then {
	# 	printf 'info: %s\n' "Waiting for the '.gitpod.yml:tasks:command' docker-pull to complete ...";
	# 	until test -s "$lckfile"; do {
	# 		sleep 0.5;
	# 	} done
	# 	rm -f "$lckfile";
	# } fi

	(sleep 2 docker container prune -f >/dev/null 2>&1) & disown;
	rm -f /tmp/.{build,install}.lock;
	exec docker "${docker_args[@]}" -c "$(printf "%s\n" "$(declare -f startup_command)" "startup_command")";
}
