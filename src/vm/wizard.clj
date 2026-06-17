(ns vm.wizard
  "Interactive VM configuration wizard (config_vm_interactive). Ported in phase 6;
  placeholder so the backend create composites can reference it.")

(defn config-vm-interactive
  "Interactive machine configuration via script-wizard. Implemented in phase 6."
  [_cfg _name _profile _from-create]
  (throw (ex-info "config-vm-interactive is implemented in phase 6 of the bb port" {})))
