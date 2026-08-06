# Unreal render rig — GovCloud infrastructure

Terraform for running the Polaris/Unreal simulation rig on GPU hardware in AWS GovCloud
(`us-gov-west-1`), instead of on a workstation.

**IT applies `polaris-sim-iam` only.** It creates the five IAM objects the rig runs as, plus the policy
that lets the render team apply everything else. Once that policy is attached, the team
applies `polaris-sim` itself and IT is not involved again.

| | who applies it | what it creates |
|---|---|---|
| `polaris-sim-iam/part-a-roles.tf` | **IT**, once | The five IAM objects the rig runs as. Part A of the access request. |
| `polaris-sim-iam/part-b-deployer.tf` | **IT**, same apply | The policy attached to the render team so they can apply `polaris-sim`. Part B of the access request. |
| `polaris-sim/main.tf` | The render team, thereafter | ECR, S3 wiring, the GPU ECS cluster, VPC endpoints, security groups, both task definitions, and the dispatch endpoint (API Gateway + Lambda). |

The two files in `polaris-sim-iam/` are one Terraform module — IT runs a single `terraform apply` in
that directory. They are split so Part B can be read on its own: it is the only thing here
granted to a person.

```bash
cd polaris-sim-iam && terraform init && terraform apply     # IT, once
```
```bash
cd polaris-sim && terraform init && terraform apply     # render team
```

They are separate directories because Terraform merges every `.tf` in a directory into one
module — in a single folder there is no way to apply only the roles, and whoever ran
`apply` would own the state for the whole stack.

Defaults are the TestDev values, so neither needs a `.tfvars` file. The two share
`artifacts_bucket` and `gis_bucket`; the task policies are scoped to those names, so if you
change one, change both.

`polaris-sim` resolves the three roles by name. If it fails with `no IAM role found`, that is the
whole diagnosis: `polaris-sim-iam` has not been applied yet.

## What it stands up

A **rig** is two ECS tasks on two GPU instances, started and stopped as a pair. They are
split because the hard real-time leg — PX4 ↔ JSBSim lockstep — must not cross a network
boundary, while every leg between Unreal and Polaris tolerates loss. Each node claims a
whole T4, so `CUDA_VISIBLE_DEVICES` never has to be reasoned about.

```
            node 0  —  g4dn.2xlarge (8 vCPU, 1x T4)
          ┌──────────────────────────────────────────┐
          │  unreal      ]                           │
          │  px4-sitl    ]  image: mach-unreal       │
          └──────────────────────────────────────────┘
                    │  frames          ▲  uORB / DDS
                    ▼                  │
          ┌──────────────────────────────────────────┐
          │  sim-image-receiver  ] polaris-unreal-…  │
          │  polaris-strike      ] polaris-cloud     │
          │  uxrce-agent         ] polaris-cloud     │
          └──────────────────────────────────────────┘
            node 1  —  g4dn.xlarge (4 vCPU, 1x T4)
```

Both task ENIs carry the same security group, so every link above is intra-SG. That is
what the self-referencing rule in `polaris-sim/main.tf` is for — without it the rig places cleanly and
then sits silent.

### Three images, five containers

`polaris-cloud` appears twice: `polaris-strike` and `uxrce-agent` are the same image under
different commands, exactly as the local compose files run them.

| image | ECR repo | node |
|---|---|---|
| Unreal renderer + PX4/JSBSim runtime | `mach-industries/mach-unreal` | 0 |
| Polaris stack (`polaris-strike`, `uxrce-agent`) | `mach-industries/polaris-cloud` | 1 |
| Frame receiver (`sim-image-receiver`) | `mach-industries/polaris-unreal-receiver` | 1 |

**PX4 is not an image.** It is built on the operator's machine and staged to S3 as a
`.tar.gz` keyed by `sha256(model + git HEAD)`, the same pattern Monte Carlo uses. This is
why nothing in the account needs GitHub egress or a PAT.

All three images are built outside GovCloud and pushed to ECR — there is no builder in the
account. `terraform output ecr_repository_urls` gives the push targets.

## How a run is dispatched

```
  mach-unreal -c cloud.toml
       │  stage config + PX4 build to S3 (content-addressed)
       │  POST /runs, signed SigV4
       ▼
  API Gateway (AWS_IAM auth)
       ▼
  Lambda "rig orchestrator"        ← the only thing holding ecs:RunTask
       │  RunTask x2, startedBy = run_id
       ▼
  node 0 + node 1                  → artifacts land in s3://…/runs/<run_id>/
```

**This is why dispatching a run needs no ECS permissions.** The orchestrator holds
`ecs:RunTask` and `iam:PassRole`; a caller holds `execute-api:Invoke` and write access to
its own run prefix. Attach `rig_invoke_policy_arn` to anyone who should be able to launch
runs — they never gain the ability to create compute in the account.

The API also serves `GET /runs/{run_id}` and `DELETE /runs/{run_id}`. A rig is both nodes
or neither: if the second task cannot be placed, the orchestrator stops the first rather
than leaving half a rig billing a GPU.

## Who can do what

| who | policy | can do |
|---|---|---|
| IT | account admin | apply `polaris-sim-iam`, once, and attach `deployer_policy_arn`. Nothing after that. |
| The render team | `deployer_policy_arn` | apply `polaris-sim` — and every change and destroy after |
| Anyone launching runs | `rig_invoke_policy_arn` | `execute-api:Invoke` + write their own run prefix. No ECS, no `PassRole`, no EC2 |
| The rig itself | `mach-gnc-polaris-sim-task`, `mach-gnc-polaris-sim-task-execution`, `mach-gnc-polaris-sim-instance` | pull images, read staged inputs, write run outputs |

The bootstrap wrinkle: creating IAM roles is itself an IAM write, so IT has to apply `polaris-sim-iam`
and attach `deployer_policy_arn` before the team can take over.

**`polaris-sim` creates no IAM roles or policies at all.** Every role and policy — including the
orchestrator Lambda's role and the `mach-gnc-polaris-sim-invoke` policy — is in `polaris-sim-iam`, specifically so the
deployer policy needs no `iam:CreateRole`. Its only IAM verb is `PassRole`, pinned to the
`rig-*` roles and conditioned to `ecs-tasks`/`ec2`/`lambda`. That is what keeps the access
request's "we are not asking for IAM write permissions" line true.

Verified against the account on 2026-08-04: `autoscaling`, `lambda` and `apigateway` are all
denied to `Mach-GNC-SW-Dev-Deploy` today, so `polaris-sim` cannot be applied until Part B is
attached. `ec2:CreateVpcEndpoint` is already held.

## Networking

There is **no NAT and no internet gateway**. Egress is default-deny with four holes:

| destination | why |
|---|---|
| `172.23.5.51:443` | Google 3D tiles, served inside the VPC |
| S3 (gateway endpoint prefix list) | artifacts, staged imagery, and ECR image layers |
| ECR + CloudWatch Logs (interface endpoints) | image pull and log delivery |
| `10.73.106.0/24` (HQ Jetsons, all protocols) | real hardware in the loop over the TGW path; tighten to explicit ports once the protocol matrix is pinned. TGW/HQ-firewall leg is a separate network-team gate |

A config that expects to fetch imagery from an external provider at run time will stall
rather than fail cleanly. Stage imagery for the area you are rendering.

## Known gaps

- **The images do not exist yet.** Apply order does not depend on them, but a rig
  dispatched before they are pushed fails at image pull.
- **No container entrypoints.** Neither image reads `RUN_CONFIG` / `PX4_BUILD` / `RUN_ID` /
  `OUTPUT_PREFIX` yet.
- **No placement timeout or retry.** A node that cannot be placed tears the pair down; a
  node that is merely slow to scale up is not retried.
- The cluster scales to zero, so the first dispatch after an idle period waits on an EC2
  cold start plus a large image pull.

Usage from the CLI side is documented in
`polaris/docs/unreal/step-3-running-in-the-cloud.md`.
