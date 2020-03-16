#!/bin/bash
# -*- mode: sh; indent-tabs-mode: nil; perl-indent-level: 4 -*-
# vim: autoindent tabstop=4 shiftwidth=4 expandtab softtabstop=4 filetype=bash

USER_NAME=""
PASSWORD=""
ACTION="start"

CONTAINER_NAME=parking-garage

REPO_DIR=$(dirname `readlink -e $0`)
SSL_DIR=${REPO_DIR}/ssl
REGISTRY_DIR=${REPO_DIR}/registry

function error() {
    msg="$@"

    echo "ERROR: ${msg}" >&2
}

while (( "$#" )); do
    case "$1" in
        --user-name)
            USER_NAME=$2
            shift 2
            ;;
        --password)
            PASSWORD=$2
            shift 2
            ;;
        --action)
            ACTION=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*|--*=)
            error "Unsupported flag '$1'"
            exit 1
            ;;
        *)
            error "Unknown positional parameter '$1'"
            exit 1
            ;;
    esac
done

function create_openssl_cnf() {
cat <<EOF > openssl.cnf
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = $(hostname --fqdn)
IP.1 = $(hostname --ip-address)
EOF
}

function setup_ssl() {
    if [ ! -e ${SSL_DIR}/ssl.cert -o ! -e ${SSL_DIR}/ssl.key ]; then
        if [ ! -d ${SSL_DIR} ]; then
            mkdir -p ${SSL_DIR}
        fi

        if pushd ${SSL_DIR} > /dev/null 2>&1; then
            create_openssl_cnf

            openssl genrsa -out rootCA.key 2048
            openssl req -x509 -new -nodes -key rootCA.key -sha256 -days 1024 -out rootCA.pem #-config openssl.cnf

            openssl genrsa -out ssl.key 2048
            openssl req -new -key ssl.key -out ssl.csr -subj "/CN=parking-garage" -config openssl.cnf
            openssl x509 -req -in ssl.csr -CA rootCA.pem -CAkey rootCA.key -CAcreateserial -out ssl.cert -days 356 -extensions v3_req -extfile openssl.cnf

            popd > /dev/null 2>&1
        else
            error "Could not pushd to SSL_DIR=${SSL_DIR}"
            exit 1
        fi
    fi
}

function setup_registry() {
    podman pull docker.io/library/registry

    mkdir -p ${REGISTRY_DIR}/certs ${REGISTRY_DIR}/auth ${REGISTRY_DIR}/storage

    if [ ! -e ${REGISTRY_DIR}/ssl.cert -o ! -e ${REGISTRY_DIR}/ssl.key ]; then
        cp ${SSL_DIR}/ssl.cert ${SSL_DIR}/ssl.key ${REGISTRY_DIR}/certs
    fi

    if [ ! -e ${REGISTRY_DIR}/auth/htpasswd ]; then
        if [ -z "${USER_NAME}" -o -z "${PASSWORD}" ]; then
            error "You must define both --user-name and --password!"
            exit 1
        fi

        podman run --rm --entrypoint htpasswd docker.io/library/registry -Bbn ${USER_NAME} ${PASSWORD} > ${REGISTRY_DIR}/auth/htpasswd
    fi
}

function stop() {
    if podman container exists ${CONTAINER_NAME}; then
        podman stop ${CONTAINER_NAME}
    fi
}

function create() {
    if ! podman container exists ${CONTAINER_NAME}; then
        podman create \
            --detach \
            --publish 443:443 \
            --name=${CONTAINER_NAME} \
            -e "REGISTRY_AUTH=htpasswd" \
            -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
            -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
            -e REGISTRY_HTTP_ADDR=0.0.0.0:443 \
            -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/ssl.cert \
            -e REGISTRY_HTTP_TLS_KEY=/certs/ssl.key \
            --mount=type=bind,source=${REGISTRY_DIR}/certs,destination=/certs \
            --mount=type=bind,source=${REGISTRY_DIR}/auth,destination=/auth \
            --mount=type=bind,source=${REGISTRY_DIR}/storage,destination=/var/lib/registry \
            --privileged=true \
            docker.io/library/registry
    fi
}

function start() {
    if podman container exists ${CONTAINER_NAME}; then
        podman start ${CONTAINER_NAME}
    fi
}

function remove() {
    stop

    if podman container exists ${CONTAINER_NAME}; then
        podman rm ${CONTAINER_NAME}
    fi
}

function cleanup() {
    stop
    remove

    rm -Rf ${SSL_DIR}
    rm -Rf ${REGISTRY_DIR}
}

ACTION=$(echo ${ACTION} | tr '[:lower:]' '[:upper:]')
case "${ACTION}" in
    "CREATE")
        setup_ssl
        setup_registry
        create
        ;;
    "START")
        setup_ssl
        setup_registry
        create
        start
        ;;
    "STOP")
        stop
        ;;
    "SETUP")
        stop
        remove
        setup_ssl
        setup_registry
        ;;
    "REMOVE")
        remove
        ;;
    "CLEANUP")
        cleanup
        ;;
    *)
        error "Unkown action '${ACTION}'"
        exit 1
        ;;
esac
