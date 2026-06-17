# Bash completion + alias setup for nixos-vm-template.
#
# Completes recipe names, then the arguments each recipe expects: VM names,
# profiles, and network modes. Argument candidates come from the private
# `_completion_*` recipes in the Justfile, so completion always matches the
# recipes actually defined, and from the backend selected by each alias's env
# file (so a libvirt alias and a proxmox alias complete their own VM names).
#
# Setup (in ~/.bashrc):
#
#     export NIXOS_VM_TEMPLATE="$HOME/nixos-vm-template"   # your clone
#     source "$NIXOS_VM_TEMPLATE/completions/vm.bash"
#
#     # vm_register <alias> <env-file> [repo-root]
#     vm_register vm  "$HOME/.config/nixos-vm-template/env"      # libvirt
#     vm_register pve "$HOME/.config/nixos-vm-template/pve.env"  # proxmox
#
# Each vm_register call defines the alias AND wires its completion to the same
# env file, so you can run e.g. `vm create web` and `pve create db` and both
# tab-complete against their own backend.

# alias name -> (repo root, env file)
declare -gA _VM_ROOTS _VM_ENVS

# vm_register <alias> <env-file> [repo-root]
# Defines the alias and registers its completion against the given env file.
vm_register() {
    local name="$1" env="$2"
    local root="${3:-${NIXOS_VM_TEMPLATE:-$HOME/nixos-vm-template}}"
    if [[ -z "$name" || -z "$env" ]]; then
        echo "usage: vm_register <alias> <env-file> [repo-root]" >&2
        return 2
    fi
    _VM_ROOTS["$name"]="$root"
    _VM_ENVS["$name"]="$env"
    alias "$name"="just -f '$root/Justfile' -d '$root' -E '$env'"
    complete -F _vm "$name"
}

# Run just against a given root/env (matching what the alias does).
_vm_run() {
    local root="$1" env="$2"; shift 2
    if [[ -n "$root" ]]; then
        just -f "$root/Justfile" -d "$root" -E "$env" "$@"
    else
        just "$@"
    fi
}

_vm() {
    local cur cmd root env
    cur="${COMP_WORDS[COMP_CWORD]}"
    cmd="${COMP_WORDS[0]}"

    # Resolve this alias's root/env, falling back to the env vars (so a plain
    # `complete -F _vm vm` without vm_register still works).
    root="${_VM_ROOTS[$cmd]:-${NIXOS_VM_TEMPLATE:-}}"
    env="${_VM_ENVS[$cmd]:-${VM_ENV:-$HOME/.config/nixos-vm-template/env}}"

    # First token: the recipe name (skip private `_` recipes).
    if (( COMP_CWORD == 1 )); then
        local recipes
        recipes=$(_vm_run "$root" "$env" --summary 2>/dev/null | tr ' ' '\n' | grep -v '^_')
        COMPREPLY=( $(compgen -W "$recipes" -- "$cur") )
        return
    fi

    local recipe="${COMP_WORDS[1]}"
    local argpos=$(( COMP_CWORD - 1 ))   # 1-based position of the argument
    local kind=""

    case "$recipe" in
        build|export)   kind=profile ;;
        config)         [[ $argpos == 1 ]] && kind=name || kind=profile ;;
        profile)        [[ $argpos == 1 ]] && kind=name || kind=profile ;;
        network-config) [[ $argpos == 1 ]] && kind=name || kind=network ;;
        clone)          (( argpos <= 2 )) && kind=name || { (( argpos == 5 )) && kind=network; } ;;
        recreate)       [[ $argpos == 1 ]] && kind=name || { (( argpos == 3 )) && kind=network; } ;;
        create-batch)   case $argpos in 1) kind=name ;; 2) kind=profile ;; 7) kind=network ;; esac ;;
        config-batch)   case $argpos in 2) kind=profile ;; 7) kind=network ;; esac ;;
        *)              [[ $argpos == 1 ]] && kind=name ;;
    esac

    case "$kind" in
        name)
            COMPREPLY=( $(compgen -W "$(_vm_run "$root" "$env" _completion_name 2>/dev/null)" -- "$cur") )
            ;;
        network)
            COMPREPLY=( $(compgen -W "$(_vm_run "$root" "$env" _completion_network 2>/dev/null)" -- "$cur") )
            ;;
        profile)
            # Profiles may be comma-separated (e.g. docker,python); complete the
            # segment after the last comma and keep the preceding ones.
            local opts; opts=$(_vm_run "$root" "$env" _completion_profile 2>/dev/null)
            if [[ "$cur" == *,* ]]; then
                COMPREPLY=( $(compgen -P "${cur%,*}," -W "$opts" -- "${cur##*,}") )
            else
                COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
            fi
            ;;
    esac
}

# If you'd rather define aliases by hand instead of using vm_register, register
# completion for each one explicitly, e.g.:  complete -F _vm vm pve
