# Bash completion + alias setup for nixos-vm-template.
#
# Completes recipe names, then each recipe's arguments. Argument completion is
# data-driven: for the argument under the cursor it reads the recipe's parameter
# name from `just --show <recipe>` and offers the output of the matching
# `_completion_<param>` recipe in the Justfile (e.g. a `name` parameter →
# `_completion_name`). Nothing here hardcodes the recipe list, so it keeps
# working as recipes change — just add a `_completion_<param>` recipe to offer
# candidates for a new parameter.
#
# Candidates are queried through the backend each alias points at, so a libvirt
# alias and a proxmox alias complete their own VM names.
#
# Setup (in ~/.bashrc):
#
#     export NIXOS_VM_TEMPLATE="$HOME/nixos-vm-template"   # your clone
#     source "$NIXOS_VM_TEMPLATE/completions/vm.bash"
#
#     # nixos-vm-template-alias <alias> <env-file> [repo-root]
#     nixos-vm-template-alias vm  "$HOME/.config/nixos-vm-template/env"      # libvirt
#     nixos-vm-template-alias pve "$HOME/.config/nixos-vm-template/pve.env"  # proxmox
#
# Each call defines the alias AND wires its completion to the same env file, so
# you can run e.g. `vm create web` and `pve create db` and both tab-complete
# against their own backend.

# alias name -> (repo root, env file)
declare -gA _VM_ROOTS _VM_ENVS

# nixos-vm-template-alias <alias> <env-file> [repo-root]
# Defines the alias and registers its completion against the given env file.
nixos-vm-template-alias() {
    local name="$1" env="$2"
    local root="${3:-${NIXOS_VM_TEMPLATE:-$HOME/nixos-vm-template}}"
    if [[ -z "$name" || -z "$env" ]]; then
        echo "usage: nixos-vm-template-alias <alias> <env-file> [repo-root]" >&2
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
    local cur cmd root env recipe
    COMPREPLY=()   # bash does not clear this between calls
    cur="${COMP_WORDS[COMP_CWORD]}"
    cmd="${COMP_WORDS[0]}"

    # Resolve this alias's root/env, falling back to the env vars (so a plain
    # `complete -F _vm vm` without nixos-vm-template-alias still works).
    root="${_VM_ROOTS[$cmd]:-${NIXOS_VM_TEMPLATE:-}}"
    env="${_VM_ENVS[$cmd]:-${VM_ENV:-$HOME/.config/nixos-vm-template/env}}"

    # First token: the recipe name (private `_` recipes aren't in --summary).
    if (( COMP_CWORD == 1 )); then
        local recipes
        recipes=$(_vm_run "$root" "$env" --summary 2>/dev/null | tr ' ' '\n' | grep -v '^_')
        COMPREPLY=( $(compgen -W "$recipes" -- "$cur") )
        return
    fi

    recipe="${COMP_WORDS[1]}"
    local arg_index=$(( COMP_CWORD - 2 ))   # 0-based positional argument

    # Pull the recipe's signature line and split it into parameter tokens.
    local sig
    sig=$(_vm_run "$root" "$env" --show "$recipe" 2>/dev/null \
            | sed -n -E -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
                        -e "/^[[:space:]]*${recipe}([[:space:]].*)?:[[:space:]]*\$/{p;q;}")
    [[ -z "$sig" ]] && return
    sig="${sig%:}"            # drop trailing colon
    sig="${sig#"$recipe"}"    # drop the recipe name
    local -a params
    read -r -a params <<<"$sig"
    (( ${#params[@]} == 0 )) && return

    # Token at this position; a trailing variadic (+x / *x) absorbs the rest.
    local tok
    if (( arg_index < ${#params[@]} )); then
        tok="${params[arg_index]}"
    else
        local last="${params[${#params[@]}-1]}"
        [[ "$last" == [+*]* ]] && tok="$last" || return
    fi

    local name="${tok#[+*]}"   # strip leading + or *
    name="${name%%=*}"         # strip =default
    [[ -z "$name" ]] && return

    # Candidates come from a `_completion_<param>` recipe, if one is defined.
    local opts
    opts=$(_vm_run "$root" "$env" "_completion_${name}" 2>/dev/null) || return
    [[ -z "$opts" ]] && return

    # Values may be comma-separated lists (e.g. profiles=docker,python): complete
    # the segment after the last comma and keep the earlier ones.
    if [[ "$cur" == *,* ]]; then
        COMPREPLY=( $(compgen -P "${cur%,*}," -W "$opts" -- "${cur##*,}") )
    else
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    fi
}

# If you'd rather define aliases by hand instead of using the helper above,
# register completion for each one explicitly, e.g.:  complete -F _vm vm pve
