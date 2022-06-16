# Publish PHP-FPM Image

This repository is for the Publish PHP-FPM Docker image. In installs and
configures PHP-FPM with desired settings, and also utilities used to monitor
and control PHP. It includes some scripts as an "agent" to reload and check
the health of PHP-FPM.

Instead of having a normal branch structure with `main` and `develop`, this
repository is organized with branches for the base Docker image. Current
branches used for building:

- `main/8.1/ubuntu22.04`
- `main/8.1/ubuntu20.04`
- `main/8.0/ubuntu22.04`
- `main/8.0/ubuntu20.04`
- `main/7.4/ubuntu22.04`: production as of June 2022.
- `main/7.4/ubuntu20.04`
- `main/7.4/ubuntu18.04`: production before June 2022.
- `main/7.3/ubuntu18.04`
- `main/7.2/ubuntu18.04`
