#!/usr/bin/env bash
# Exit the script in case of an error
set -e

BOOKIE_PORT=${bookiePort:-${BOOKIE_PORT}}
BOOKIE_PORT=${BOOKIE_PORT:-3181}
BOOKIE_HTTP_PORT=${BOOKIE_HTTP_PORT:-8080}
BK_zkServers=$(echo "${ZK_URL:-127.0.0.1:2181}" | sed -r 's/;/,/g')
ZK_URL=$(echo "${ZK_URL:-127.0.0.1:2181}" | sed -r 's/,/;/g')
BOSS_PATH=${BOSS_PATH:-"boss"}
CLUSTER_NAME=${CLUSTER_NAME:-"bk-cluster"}
BK_CLUSTER_NAME=${BK_CLUSTER_NAME:-"bookkeeper"}
# ledger path should resolve to "/boss/wal-N/bookkeeper/ledgers"
BK_LEDGERS_PATH="/${BOSS_PATH}/${CLUSTER_NAME}/${BK_CLUSTER_NAME}/ledgers"
BK_DIR="/bk"
BK_zkLedgersRootPath=${BK_LEDGERS_PATH}
BK_HOME=/opt/bookkeeper
SCRIPTS_DIR=${BK_HOME}/scripts

export PATH=$PATH:/opt/bookkeeper/bin
export BK_zkLedgersRootPath=${BK_LEDGERS_PATH}
export BOOKIE_PORT=${BOOKIE_PORT}
export SERVICE_PORT=${BOOKIE_PORT}
export BK_bookiePort=${BK_bookiePort:-${BOOKIE_PORT}}
export BK_zkServers=${BK_zkServers}
export BK_metadataServiceUri=zk://${ZK_URL}${BK_LEDGERS_PATH}
export BK_zkTimeout=${BK_zkTimeout:-30000}
export BK_journalDirectories=${BK_journalDirectories:-${BK_DIR}/journal}
export BK_ledgerDirectories=${BK_ledgerDirectories:-${BK_DIR}/ledgers}
export BK_indexDirectories=${BK_indexDirectories-${BK_DIR}/index}
export BK_CLUSTER_ROOT_PATH=/${BOSS_PATH}/${CLUSTER_NAME}/${BK_CLUSTER_NAME}

export BK_tlsProvider=${BK_tlsProvider:-OpenSSL}
export BK_tlsKeyStoreType=${BK_tlsKeyStoreType:-JKS}
export BK_tlsKeyStore=${BK_tlsKeyStore:-/var/private/tls/bookie.keystore.jks}
export BK_tlsKeyStorePasswordPath=${BK_tlsKeyStorePasswordPath:-/var/private/tls/bookie.keystore.passwd}
export BK_tlsTrustStoreType=${BK_tlsTrustStoreType:-JKS}
export BK_tlsTrustStore=${BK_tlsTrustStore:-/var/private/tls/bookie.truststore.jks}
export BK_tlsTrustStorePasswordPath=${BK_tlsTrustStorePasswordPath:-/var/private/tls/bookie.truststore.passwd}

# The default number of backup journals is 5, which means we expect 6 journals per directory: 1 active and 5 backups.
# We also should expect one more that requires rotation, so we should expect up to 7 journal files at any given time
# with the defaults.
# Cutting the number of backup journals cuts down on the required disk space by 2 GB * Number of Directories per
# decrement.
# Setting this to 3 allows us to only expect 5 journal files per directory, 1 active + 1 pending deletion + 3 backups.
export BK_journalMaxBackups=3

# If zookeeper tls is enabled, we run socat on this port to handle the TLS
# connection, since zk-shell doesn't natively support TLS.
export SOCAT_LOCAL_PORT=9001
zk_shell_init() {
    if [[ "$ZOOKEEPER_TLS_ENABLED" == "true" ]]; then
      # Note that we are forcing TLS v1.2 for Ed25519 access
      # ZooKeeper doesn't support TLS v1.3.
      socat tcp-listen:"$SOCAT_LOCAL_PORT",reuseaddr,fork openssl:"$ZK_URL",cert=/certs/tls.crt,key=/certs/tls.key,cafile=/certs/ca.crt,openssl-min-proto-version=TLS1.2 &
    fi
}

zk_shell_run() {
    # Note that we're using the PIP package zk-shell, with source code available at
    # https://github.com/rgs1/zk_shell. It's not very good (see the pile of `grep` down below)
    # and we should consider replacing it.
    if [[ "$ZOOKEEPER_TLS_ENABLED" == "true" ]]; then
        ZK_SHELL_OUTPUT=$(zk-shell --run-once "$*" "localhost:${SOCAT_LOCAL_PORT}" 2>&1)
    else
        ZK_SHELL_OUTPUT=$(zk-shell --run-once "$*" "${BK_zkServers}" 2>&1)
    fi
    ZK_SHELL_RC=$?

    echo "$ZK_SHELL_OUTPUT"
    if [[ $ZK_SHELL_RC -ne 0 ]]; then
        return $ZK_SHELL_RC
    else
        # zk-shell effectively never returns a non-zero status. We have to trap error conditions
        # that we have seen here and return a failing status when they occur.
        echo "$ZK_SHELL_OUTPUT" | grep -q "Not connected." && echo "zk-shell: Can't connect" && return 1
        echo "$ZK_SHELL_OUTPUT" | grep -q "Connection loss." && echo "zk-shell: Lost connection" && return 1
        echo "$ZK_SHELL_OUTPUT" | grep -q "Path [^ ]\\+ doesn't exist" && echo "zk-shell: Path does not exist" && return 1
        echo "$ZK_SHELL_OUTPUT" | grep -q "Path [^ ]\\+ already exists" && echo "zk-shell: Path already exists" && return 1

        return 0
    fi
}

# Create directories for multiple ledgers and journals if specified.
create_bookie_dirs() {
  IFS=',' read -ra directories <<< "$1"
  for i in "${directories[@]}"
  do
      mkdir -p "$i"
      if [[ "$(id -u)" = '0' ]]; then
          chown -R "${BK_USER}:${BK_USER}" "$i"
      fi
  done
}

# Create a Bookie ID if this is a newly added bookkeeper pod
# or read the Bookie ID if a cookie containing this value already exists
set_bookieid() {
  IFS=',' read -ra journal_directories <<< "$BK_journalDirectories"
  COOKIE="${journal_directories[0]}/current/VERSION"
  if [[ $(find "$COOKIE" | wc -l) -gt 0 ]]; then
    # Reading the Bookie ID value from the existing cookie
    bkHost=$(grep bookieHost "$COOKIE")
    IFS=" " read -ra id <<< "$bkHost"
    BK_bookieId=${id[1]:1:-1}
  else
    # Creating a new Bookie ID following the latest nomenclature
    BK_bookieId="$(hostname -s)-${RANDOM}"
  fi
  echo "BookieID = $BK_bookieId"
  sed -i "s|.*bookieId=.*\$|bookieId=${BK_bookieId}|" ${BK_HOME}/conf/bk_server.conf
}

wait_for_zookeeper() {
    echo "Waiting for zookeeper"
    until zk_shell_run "ls /"; do sleep 5; done
}

create_zk_root() {
  if [[ -n "${BK_CLUSTER_ROOT_PATH}" ]]; then
    echo "Creating the zk root dir '${BK_CLUSTER_ROOT_PATH}' at '${BK_zkServers}'"

    set +e
    zk_shell_run "create ${BK_CLUSTER_ROOT_PATH} '' false false true"
    ZK_CREATE_RC=$?
    set -e

    if [[ $ZK_CREATE_RC -ne 0 ]]; then
      zk_shell_run "ls ${BK_CLUSTER_ROOT_PATH}" && echo "${BK_CLUSTER_ROOT_PATH} already exists"
    fi
  fi
}

configure_bk() {
    # We need to update the metadata endpoint and Bookie ID before attempting to delete the cookie
    sed -i "s|.*metadataServiceUri=.*\$|metadataServiceUri=${BK_metadataServiceUri}|" /opt/bookkeeper/conf/bk_server.conf
    sed -i "s|.*zkTimeout=.*\$|zkTimeout=${BK_zkTimeout}|" /opt/bookkeeper/conf/bk_server.conf
    if [[ -n "$BK_useHostNameAsBookieID" ]]; then
      sed -i "s|.*useHostNameAsBookieID=.*\$|useHostNameAsBookieID=${BK_useHostNameAsBookieID}|" ${BK_HOME}/conf/bk_server.conf
    fi
}

initialize_cluster() {
    set +e

    if zk_shell_run "ls ${BK_zkLedgersRootPath}/available/readonly"; then
        echo "Cluster metadata already exists"
        return
    fi

    tenSeconds=1
    while [[ ${tenSeconds} -lt 20 ]]; do
        # Create an ephemeral zk node `bkInitLock` for use as a lock.
        if zk_shell_run "create ${BK_CLUSTER_ROOT_PATH}/bkInitLock '' true false false"; then
            if zk_shell_run "ls ${BK_zkLedgersRootPath}/available/readonly"; then
                echo "Cluster metadata already exists"
                return
            fi

            echo "Bookkeeper znodes do not exist in Zookeeper. Initializing a new Bookeekeper cluster."

            # Note that this `bookkeeper` shell script sets "exit on error" (`set -e`) and sources from
            # ${SCRIPTS_DIR}/common.sh. Make sure to invoke `fix_bk_ipv6_check()` before the control reaches here.
            /opt/bookkeeper/bin/bookkeeper shell initnewcluster
            newcluster_result=$?
            if [[ $newcluster_result -eq 0 ]]; then
                echo "initnewcluster operation succeeded"
                return 0
            else
                echo "initnewcluster operation failed. Please check the reason."
                echo "Exit status of initnewcluster: ${newcluster_result}"
                # This exit is intentional: if we can't initialize the new cluster, we have to fully bail.
                exit $newcluster_result
            fi
        else
            echo "Another instance might be initializing the cluster at the same time."
            zk_shell_run "ls ${BK_zkLedgersRootPath}/available/readonly"
            if zk_shell_run "ls ${BK_zkLedgersRootPath}/available/readonly"; then
                echo "Successfully listed ''${BK_zkLedgersRootPath}/available/readonly'"
                break
            else
                sleep 10
                echo "Waited $tenSeconds * 10 seconds. Continue waiting."
                (( tenSeconds++ ))
                continue
            fi

            if [[ ${tenSeconds} -eq 20 ]]; then
                echo "Waited ${tenSeconds} * 20 seconds for bookkeeper cluster to initialize, but to no avail. Something is wrong, please check."
                exit
            fi
        fi
    done
    set -e
}

format_bookie_data_and_metadata() {
    IFS=',' read -ra journal_directories <<< "$BK_journalDirectories"
    IFS=',' read -ra ledger_directories <<< "$BK_ledgerDirectories"
    IFS=" " eval 'directory_names="${journal_directories[*]} ${ledger_directories[*]}"'
    if [[ "$(find "$directory_names" "$BK_indexDirectories" -type f 2> /dev/null | wc -l)" -gt 0 ]]; then
      # The container already contains data in BK directories. Examples of when this can happen include:
      #    - A container was restarted, say, in a non-Kubernetes deployment.
      #    - A container running on Kubernetes was updated/evacuated, and
      #      it did not lose its persistent volumes.
      echo "Data available in bookkeeper directories; not formatting the bookie"
    else
      # The container does not contain any BK data, and it is likely a new
      # bookie. We will format any pre-existent data and metadata before starting
      # the bookie to avoid potential conflicts.
      echo "Formatting bookie data and metadata"
      /opt/bookkeeper/bin/bookkeeper shell bookieformat -nonInteractive -force -deleteCookie || true
    fi
}


# Setup TLS connection if needed for Zookeeper shell commands.
zk_shell_init

# The reason for creating custom journal and ledger files here is to support
# multi ledger/journal scenarios for better write performance. It was found that
# performance can be increased by increasing write parallelism for those files.
#
# However, during those experiments it was also found that index dir has a very low write
# throughput, so using the default settings for it should not have any negative effect
# on performance. Therefore, we do not set the paths for index directories below.
echo "Creating directories for Bookkeeper journal and ledgers"
create_bookie_dirs "${BK_journalDirectories}"
create_bookie_dirs "${BK_ledgerDirectories}"

echo "Configuring the Bookie ID"
set_bookieid

echo "Sourcing ${SCRIPTS_DIR}/common.sh"
source "${SCRIPTS_DIR}/common.sh"

echo "Waiting for Zookeeper to come up"
wait_for_zookeeper

echo "Creating Zookeeper root"
create_zk_root

echo "Configuring Bookkeeper"
configure_bk

echo "Formatting Bookie data and metadata, if needed"
format_bookie_data_and_metadata

echo "Initializing Cluster"
initialize_cluster

echo "BK_CLUSTER_ROOT_PATH = $BK_CLUSTER_ROOT_PATH"
echo "BK_LEDGERS_PATH = $BK_LEDGERS_PATH"

echo "Starting the bookie"
/opt/bookkeeper/bin/bookkeeper bookie