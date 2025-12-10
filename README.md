# scripts

This repo contains various scripts used throughout hartwig production processes.

Add the following code to `.bashrc` file to make all executable scripts function as commands
```shell
for d in $(find /data/repos/production-scripts/* -type d | grep -v '.git'); do
    export PATH="${PATH}:$d"
done
```
