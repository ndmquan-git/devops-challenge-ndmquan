# DevOps Challenge Solutions

My solutions to a DevOps challenge.

## Layout

| Problem | Path | Contents | CI |
|---|---|---|---|
| 1 | [src/problem1](src/problem1/SOLUTION.md) | Highly available trading system on AWS | [![p1-ci](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p1-ci.yml/badge.svg)](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p1-ci.yml) |
| 2 | [src/problem2](src/problem2/SOLUTION.md) | Troubleshooting a full disk on an NGINX load balancer | [![p2-ci](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p2-ci.yml/badge.svg)](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p2-ci.yml) |
| 3 | [src/problem3](src/problem3/SOLUTION.md) | Stabilizing a Docker Compose stack (Nginx, Node.js API, PostgreSQL, Redis) | [![p3-ci](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p3-ci.yml/badge.svg)](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p3-ci.yml) |
| 4 | [src/problem4](src/problem4/SOLUTION.md) | CI/CD for an API on EC2 and an SPA on S3 | [![p4-backend](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p4-backend.yml/badge.svg)](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p4-backend.yml) [![p4-frontend](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p4-frontend.yml/badge.svg)](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p4-frontend.yml) [![p4-infra](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p4-infra.yml/badge.svg)](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p4-infra.yml) [![p4-docs](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p4-docs.yml/badge.svg)](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p4-docs.yml) |
| 5 | [src/problem5](src/problem5/SOLUTION.md) | Security built into the Problem 1 design | [![p5-ci](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p5-ci.yml/badge.svg)](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/p5-ci.yml) |

[![repo-checks](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/repo-checks.yml/badge.svg)](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/repo-checks.yml) runs actionlint, zizmor, gitleaks and a Trivy filesystem scan on every push, and [![code-analysis](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/code-analysis.yml/badge.svg)](https://github.com/ndmquan-git/devops-challenge-ndmquan/actions/workflows/code-analysis.yml) runs CodeQL on the JavaScript, plus dependency review on pull requests.

## CI

Every problem has its own workflow in [`.github/workflows/`](.github/workflows/). Pull requests run only the workflows whose folder changed. Every push to `main` runs all of them, so each badge always describes the latest commit.

Stages that several problems share are reusable workflows:

| Template | Stages | Used by |
|---|---|---|
| `_docs.yml` | markdownlint, local link and anchor check, shellcheck | 1, 2, 3, 4, 5 |
| `_node.yml` | `npm ci`, lint, unit tests, `npm audit`, optional build and artifact upload | 3, 4 |
| `_container.yml` | hadolint, image build, Trivy image scan; on `main`, publish by digest with a keyless signature and a provenance attestation | 3, 4 |
| `_deploy-ec2.yml`, `_deploy-s3.yml` | Signature and provenance verification, then a rolling EC2 deploy through SSM; S3 and CloudFront publish with automatic restore | 4 |

## Running problem 3

Requires Docker with Docker Compose.

```bash
cd src/problem3
cp .env.example .env    # then set POSTGRES_PASSWORD and APP_DB_PASSWORD, e.g. openssl rand -base64 20
docker compose down -v  # the app role is created only on an empty database volume
docker compose up --build --wait
./tests/smoke.sh
```

The API is served at <http://localhost:8080/api/users>.
