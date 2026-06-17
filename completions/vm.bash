# Bash completion for the nixos-vm-template `vm` alias (and `just`).
#
# Completes recipe names, then the arguments each recipe expects: VM names,
# profiles, and network modes. Argument candidates come from the private
# `_completion_*` recipes in the Justfile, so completion always matches the
# recipes actually defined.
#
# Setup (in ~/.bashrc, after defining the `vm` alias):
#
#     export NIXOS_VM_TEMPLATE="$HOME/nixos-vm-template"   # your clone
#     source "$NIXOS_VM_TEMPLATE/completions/vm.bash"
#
# The completion reuses $NIXOS_VM_TEMPLATE (and the env file at
# $VM_ENV, default ~/.config/nixos-vm-template/env) to query the same
# Justfile/backend the alias uses. If $NIXOS_VM_TEMPLATE is unset it falls
# back to plain `just`, which works when your shell is inside the repo.

# Invoke just against the same Justfile/env the `vm` alias targets.
_vm_just() {
    local root="${NIXOS_VM_TEMPLATE:-}"
    if [[ -n "$root" ]]; then
        just -f "$root/Justfile" -d "$root" \
            -E "${VM_ENV:-$HOME/.config/nixos-vm-template/env}" "$@"
    else
        just "$@"
    fi
}

_vm() {
    local cur prev cword
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    cword=$COMP_CWORD

    # First token: the recipe name (skip private `_` recipes).
    if (( cword == 1 )); then
        local recipes
        recipes=$(_vm_just --summary 2>/dev/null | tr ' ' '\n' | grep -v '^_')
        COMPREPLY=( $(compgen -W "$recipes" -- "$cur") )
        return
    fi

    local recipe="${COMP_WORDS[1]}"
    local argpos=$(( cword - 1 ))   # 1-based position of the argument
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
            COMPREPLY=( $(compgen -W "$(_vm_just _completion_name 2>/dev/null)" -- "$cur") )
            ;;
        network)
            COMPREPLY=( $(compgen -W "$(_vm_just _completion_network 2>/dev/null)" -- "$cur") )
            ;;
        profile)
            # Profiles may be comma-separated (e.g. docker,python); complete the
            # segment after the last comma and keep the preceding ones.
            local opts; opts=$(_vm_just _completion_profile 2>/dev/null)
            if [[ "$cur" == *,* ]]; then
                COMPREPLY=( $(compgen -P "${cur%,*}," -W "$opts" -- "${cur##*,}") )
            else
                COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
            fi
            ;;
    esac
}

# Register for the `vm` alias. Add more alias names here if you use several
# (e.g. `complete -F _vm vm vm-lab vm-prod`). Not registered for bare `just`:
# it would complete this repo's recipes in every other just project.
complete -F _vm vm
