#!/usr/bin/env bash
# Bash tab-completion for fwp
# Install: echo 'source /opt/fwp/completions/fwp.bash' >> ~/.bashrc

_fwp_completions() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  case "${COMP_WORDS[1]}" in
    site)
      if [[ "${COMP_CWORD}" -eq 2 ]]; then
        COMPREPLY=($(compgen -W "create delete enable disable list info" -- "${cur}"))
      elif [[ "${COMP_WORDS[2]}" =~ ^(delete|enable|disable|info)$ ]]; then
        local sites=()
        for f in /etc/fwp/sites/*.conf 2>/dev/null; do
          [[ -f "${f}" ]] && sites+=("$(basename "${f}" .conf)")
        done
        COMPREPLY=($(compgen -W "${sites[*]:-}" -- "${cur}"))
      elif [[ "${COMP_WORDS[2]}" == "create" ]]; then
        COMPREPLY=($(compgen -W "--locale= --title= --admin-email= --admin-user= --skip-redis --skip-ssl --no-worker --www --no-www --wpsc --wprocket --wpce --nocache --cache=" -- "${cur}"))
      fi ;;
    stack)
      COMPREPLY=($(compgen -W "status upgrade" -- "${cur}")) ;;
    firewall)
      COMPREPLY=($(compgen -W "status allow deny" -- "${cur}")) ;;
    *)
      COMPREPLY=($(compgen -W "site stack firewall version help" -- "${cur}")) ;;
  esac
}
complete -F _fwp_completions fwp
