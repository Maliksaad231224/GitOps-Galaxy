# Project Checklist: What Is Done and What Is Left

This checklist is based on `need.txt`, `questions.txt`, and the repo flow in `Vagrantfile`, `execution.sh`, and `scripts/`.

## What is already in the repo

- [x] `Vagrantfile` provisions an Ubuntu Jammy VM with the expected IP, CPU, RAM, and synced project folder.
- [x] `execution.sh` acts as the main orchestration entrypoint for the local setup.
- [x] Docker setup scripts exist in `scripts/docker.sh` and `scripts/dockerPermissions.sh`.
- [x] K3s setup exists in `scripts/kubernetes.sh`.
- [x] Database provisioning exists in `scripts/database.sh` using the Bitnami PostgreSQL Helm chart.
- [x] The app Helm chart exists under `helm-charts/sherlock-app/` with separate values files for dev, staging, and prod.
- [x] ArgoCD application manifests exist under `argocd/applications/` for dev, staging, prod, and database.
- [x] Resource quota manifests exist under `environments/dev`, `environments/staging`, and `environments/prod`.
- [x] A local deployment flow exists in `scripts/local-deploy.sh` for namespaces, ArgoCD install, app sync, and verification.
- [x] Project documentation folders exist under `docs/`, `manifests/`, and `scripts/`.

## What you already did

- [x] You created the Helm chart structure for the application.
- [x] You separated configuration by environment with Helm values files.
- [x] You added ArgoCD application definitions for multiple environments.
- [x] You added a database setup script with a job-based connectivity test.
- [x] You added the VM provisioning and bootstrap scripts needed to start the stack.

## What is still left

- [ ] Fix the end of `execution.sh`, which currently ends with an incomplete `./database` command.
- [ ] Verify `vagrant up` completes successfully end to end.
- [ ] Verify Docker login, image builds, and pushes actually succeed with real credentials.
- [ ] Verify K3s comes up cleanly and `kubectl` can talk to the cluster.
- [ ] Verify the PostgreSQL deployment and the test job run successfully.
- [ ] Verify the application Helm chart renders and deploys correctly in all environments.
- [ ] Verify ArgoCD installs, logs in, and syncs the apps correctly.
- [ ] Add or finish ArgoCD Image Updater configuration.
- [ ] Add or finish external secret management integration.
- [ ] Add or finish a real CI/CD pipeline definition if one is expected.
- [ ] Verify RBAC, sync options, rollback behavior, and drift correction.
- [ ] Validate persistence by inserting data, restarting the database pod, and confirming the data survives.
- [ ] Clean up placeholder or empty files such as `argocd/application-image-updater.yaml` if they are not meant to stay placeholders.

## Requirement areas still to prove

- [ ] Helm deployment explanation and chart best practices.
- [ ] ArgoCD UI and CLI access.
- [ ] Multi-environment behavior across dev, staging, and prod.
- [ ] Rollback and drift correction behavior.
- [ ] Image updater write-back behavior.
- [ ] Secret management and RBAC hardening.

## Short summary

- Done in source: VM bootstrap, Docker/K3s setup, Helm chart structure, ArgoCD app manifests, and database provisioning scripts.
- Left to finish or verify: the final execution path, end-to-end cluster runs, image updater, external secrets, CI/CD automation, and proof of rollback/drift/persistence behavior.
