# Production scripts

This repo contains various scripts used throughout hartwig production processes.

Add the following code to `.bashrc` file to make all executable scripts function as commands
```shell
for d in $(find /data/repos/production-scripts/* -type d | grep -v 'shallow-qc' | grep -v '.git'); do
    export PATH="${PATH}:$d"
done
```

## Shallow QC

The [shallow-qc](./shallow-qc/README.md) tool is a Kotlin version of a part of the
[perform_shallow_qc_gcp](shallowseq/perform_shallow_qc_gcp) script packaged as a Docker image.
