#!/usr/bin/env bash
# Leafref in a submodule-only import: ensure CLI tab-completion picks up the imported namespace
# Matches the issue #637 reproducer (test-platform/test-main/test-sub/test-if) where
# auto-complete of `set top iface-ref interface <TAB>` failed with missing tif namespace.

# Magic line must be first in script (see README.md)
s="$_"
. ./lib.sh || if [ "$s" = $0 ]; then exit 0; else return 0; fi

APPNAME=example

cfg=$dir/submodule_import_leafref.xml
fplatform=$dir/test-platform.yang
fmain=$dir/test-main.yang
fsub=$dir/test-sub.yang
fif=$dir/test-if.yang

cat <<EOF >$cfg
<clixon-config xmlns="http://clicon.org/config">
  <CLICON_CONFIGFILE>$cfg</CLICON_CONFIGFILE>
  <CLICON_YANG_DIR>$dir</CLICON_YANG_DIR>
  <CLICON_YANG_DIR>${YANG_INSTALLDIR}</CLICON_YANG_DIR>
  <CLICON_YANG_MAIN_FILE>$fplatform</CLICON_YANG_MAIN_FILE>
  <CLICON_CLISPEC_DIR>/usr/local/lib/$APPNAME/clispec</CLICON_CLISPEC_DIR>
  <CLICON_CLI_DIR>/usr/local/lib/$APPNAME/cli</CLICON_CLI_DIR>
  <CLICON_CLI_MODE>$APPNAME</CLICON_CLI_MODE>
  <CLICON_SOCK>/usr/local/var/run/$APPNAME.sock</CLICON_SOCK>
  <CLICON_BACKEND_PIDFILE>/usr/local/var/run/$APPNAME.pidfile</CLICON_BACKEND_PIDFILE>
  <CLICON_XMLDB_DIR>/usr/local/var/$APPNAME</CLICON_XMLDB_DIR>
</clixon-config>
EOF

cat <<'EOF' >$fplatform
module test-platform {
  yang-version 1.1;
  namespace "urn:test:platform";
  prefix tp;

  import test-main { prefix tm; }
  import test-if   { prefix tif; }

  /* Entry point that pulls in the test modules */
}
EOF

cat <<'EOF' >$fmain
module test-main {
  yang-version 1.1;
  namespace "urn:test:main";
  prefix tm;

  include test-sub;

  container top {
    uses sub-top;
  }
}
EOF

cat <<'EOF' >$fsub
submodule test-sub {
  belongs-to test-main { prefix tm; }
  yang-version 1.1;

  import test-if { prefix tif; }

  grouping sub-top {
    container iface-ref {
      leaf interface {
        type leafref {
          path "/tif:interfaces/tif:interface/tif:name";
        }
      }
    }
  }
}
EOF

cat <<'EOF' >$fif
module test-if {
  yang-version 1.1;
  namespace "urn:test:if";
  prefix tif;

  container interfaces {
    list interface {
      key "name";
      leaf name {
        type string;
      }
    }
  }
}
EOF

new "test params: -f $cfg"

if [ $BE -ne 0 ]; then
  new "kill old backend"
  sudo clixon_backend -zf $cfg
  if [ $? -ne 0 ]; then
    err
  fi
  new "start backend -s init -f $cfg"
  start_backend -s init -f $cfg
fi

new "wait backend"
wait_backend

XML=$(
  cat <<EOF
<interfaces xmlns="urn:test:if">
  <interface>
    <name>foo</name>
  </interface>
</interfaces>
<top xmlns="urn:test:main">
  <iface-ref>
    <interface>foo</interface>
  </iface-ref>
</top>
EOF
)

new "edit-config with leafref defined in submodule import"
expecteof_netconf "$clixon_netconf -qf $cfg" 0 "$DEFAULTHELLO" "<rpc $DEFAULTNS><edit-config><target><candidate/></target><config>$XML</config></edit-config></rpc>" "" "<rpc-reply $DEFAULTNS><ok/></rpc-reply>"

new "validate candidate containing imported-prefix leafref"
expecteof_netconf "$clixon_netconf -qf $cfg" 0 "$DEFAULTHELLO" "<rpc $DEFAULTNS><validate><source><candidate/></source></validate></rpc>" "" "<rpc-reply $DEFAULTNS><ok/></rpc-reply>"

new "discard-changes"
expecteof_netconf "$clixon_netconf -qf $cfg" 0 "$DEFAULTHELLO" "<rpc $DEFAULTNS><discard-changes/></rpc>" "" "<rpc-reply $DEFAULTNS><ok/></rpc-reply>"

new "cli add interface to serve as leafref target"
expectpart "$($clixon_cli -1 -f $cfg set interfaces interface foo)" 0 "^$"

new "cli tab-complete leafref using submodule import"
expectpart "$(printf 'set top iface-ref interface \t\n' | $clixon_cli -f $cfg 2>&1)" 0 foo --not-- "Prefix tif does not have an associated namespace" "Database error"

new "cli discard"
expectpart "$($clixon_cli -1f $cfg discard)" 0 "^$"

if [ $BE -ne 0 ]; then
  new "Kill backend"
  # Check if premature kill
  pid=$(pgrep -u root -f clixon_backend)
  if [ -z "$pid" ]; then
    err "backend already dead"
  fi
  # kill backend
  stop_backend -f $cfg
fi

rm -rf $dir

new "endtest"
endtest
