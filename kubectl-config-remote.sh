#!/bin/bash
set -e +x

Help()
{
    echo "USAGE:"
    echo "$0 [-h] [-s <k8sHost>] [-c <cluster>] [-u <user>]"

    echo "Retrieve k3s credentials and add it to your local kubectl config"
    echo
    echo "-h                Display this help"
    echo "-s <k8sHost>      k8sHost to access for credentials (mandatory)"
    echo "-u <user>         User for ssh connection to host (default: pi)"
    echo "-c <cluster>      local clustername used for cluster, context and credetials in kube-config (default: sloth)"   
}

user=pi
cluster=sloth

while getopts ":hs:u:c:" option; do
    case $option in
        h) # display Help
            Help
            exit;;
        s) # set host
            k8sHost=$OPTARG
            ;;
        u) # set user
            user=$OPTARG
            ;;
        c) # set cluster
            cluster=$OPTARG
            ;;
        \?) # Invalid option
            echo "Error: Invalid option"
            Help
            exit 2;;
    esac
done

credentials=${cluster}_root
context=${cluster}-root

if [ -z "$k8sHost" ]; then
    echo "\"k8sHost\" unset (use -s flag)... no host to contact" 1>&2
    Help;
    exit 2;
fi

echo Using Host \"${k8sHost}\" to retrieve certificates

mkdir -p .secrets/${k8sHost}/
chmod 700 .secrets/${k8sHost}/

echo Get yaml ...       
scp ${user}@${k8sHost}:/etc/rancher/k3s/k3s.yaml .secrets/${k8sHost}/

echo Extract Secrets ...
pwd=$(pwd)
cd .secrets/${k8sHost}/
cat k3s.yaml | grep certificate-authority-data | cut -d: -f2 | xargs | base64 -d > certificate-authority.crt
cat k3s.yaml | grep client-certificate-data | cut -d: -f2 | xargs | base64 -d  > client-certificate.crt
cat k3s.yaml | grep client-key-data | cut -d: -f2 | xargs | base64 -d > client.key

echo Set the cluster ${cluster} ...
kubectl config set-cluster ${cluster} --server=https://${k8sHost}:6443 --embed-certs=true --certificate-authority=certificate-authority.crt

echo Set the credentials ${credentials} ...
kubectl config set-credentials ${credentials} --embed-certs=true --client-certificate=client-certificate.crt --client-key=client.key

echo Set the context ${context} ...
kubectl config set-context ${context} --cluster ${cluster} --user ${credentials}

echo Use the context ...
kubectl config use-context ${context}

echo Delete temporary certificate and key files
cd ${pwd}
rm -rf .secrets/${k8sHost}/

echo Test the context ...
kubectl cluster-info