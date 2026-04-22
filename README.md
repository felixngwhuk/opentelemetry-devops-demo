# Web App Project Notes

This repository is a fork of
[`open-telemetry/opentelemetry-demo`][upstream-demo].

I use the upstream application as a realistic multi-service workload, but
the main purpose of this repository is to show how I package, build,
version, and promote a containerised application through a GitOps-based
delivery flow. The application itself is not heavily rewritten; the
emphasis is on the delivery model around it.

## How this repository fits into the full portfolio

The portfolio is split into three repositories so that infrastructure,
application delivery, and cluster state are kept separate:

- **Infra** - AWS networking, EKS, and cluster bootstrap
  <https://github.com/felixngwhuk/opentelemetry-devops-demo-infra>
- **Web app** - application source code and container image build logic
  <https://github.com/felixngwhuk/opentelemetry-devops-demo>
- **GitOps** - Argo CD application definitions and deployment manifests
  <https://github.com/felixngwhuk/opentelemetry-devops-demo-gitops>

I chose this split because each repository has a different lifecycle:

- infrastructure changes are slower and need a different review path
- application code changes happen more frequently
- deployment state should be visible and auditable in GitOps without
  mixing it with build logic

## Skills demonstrated by this repository

- GitHub Actions workflow design for pull requests, environment promotion,
  and release tagging
- Trunk-based development with release branches and semantic version tags
- Container image build, versioning, and promotion in GitHub Container
  Registry
- Separation of CI responsibilities in the application repository and CD
  responsibilities in a GitOps repository
- GitOps delivery with Argo CD as the deployment reconciler
- Domain-based ingress design for an EKS-hosted application exposed
  through Route 53, AWS load balancing, and Traefik

## What changed from upstream and why

Compared with the upstream demo, the main changes in this repository are
around delivery and packaging rather than business features.

### 1. CI/CD was reshaped around environment promotion

The upstream project already includes its own workflows, but this fork
replaces that release flow with a branch and tag model that matches how I
wanted to demonstrate environment promotion.

Custom workflows added in this repository:

- `.github/workflows/ci-pr.yml`
- `.github/workflows/deploy-dev.yml`
- `.github/workflows/deploy-staging.yml`
- `.github/workflows/deploy-prod.yml`
- `.github/workflows/quality-checks.yml`
- `.github/workflows/update-gitops.yml`

Several upstream workflows were moved into `.github/workflows-disabled/`
instead of being kept active. I chose that approach so the original
automation is still visible for reference, while making it clear which
workflows belong to this portfolio design.

### 2. The repository now uses a trunk-based flow with release branches

The deployment flow is:

- **Pull request to `main`**: build and test only
- **Merge to `main`**: build images and update the **dev** deployment
  state in the GitOps repository
- **Push to `version/*`**: promote/build images for **staging**
- **Push a semantic version tag**: promote/build images for
  **production**

I chose this model because it shows a clear path from integration to
release without making the demo depend on manual image editing. It also
gives each environment a predictable trigger:

- `main` acts as the active development trunk
- `version/*` branches act as release preparation branches
- semantic version tags act as the production release marker

### 3. Image naming was changed to one repository per service in GHCR

A large part of the diff is the move from upstream image tags such as:

- `ghcr.io/open-telemetry/demo:<version>-frontend`

to service-specific repositories such as:

- `ghcr.io/felixngwhuk/opentelemetry-devops-demo/frontend:<tag>`

This change appears across:

- `.env`
- `docker-compose.yml`
- `docker-compose.minimal.yml`
- `docker-compose-tests.yml`
- `.github/workflows/component-build-images.yml`

I chose one image repository per service because it makes image ownership
and promotion easier to reason about in GitOps. In particular, it
simplifies:

- per-service image references in deployment state
- retagging or promoting a single service image if needed
- browsing package history in GHCR
- keeping the image name aligned with the service name

### 4. Build workflows support promotion as well as rebuild

`.github/workflows/component-build-images.yml` was changed so a workflow
can either:

- build an image from source, or
- promote an existing image by retagging it in GHCR

The staging and production workflows use this to promote images forward
when a prior tag already exists.

I chose this because it demonstrates an important delivery idea: later
environments do not always need a fresh rebuild. Promoting the same
artifact forward makes it easier to say what was actually tested in the
earlier environment.

### 5. GitOps handoff is done by updating a separate repository

This repository does not perform direct cluster deployment in CD. Instead,
the GitHub Actions pipeline updates the GitOps repository through
`.github/workflows/update-gitops.yml`.

That workflow updates the target environment in the GitOps repository by
changing the image tags and version metadata that Argo CD watches.

I chose this approach because it keeps deployment intent in the GitOps
repository, where Argo CD can reconcile it. The web app repository
remains responsible for producing versioned artifacts; the GitOps
repository remains responsible for desired cluster state.

## Delivery flow

### Pull request checks

When a pull request targets `main`, the pipeline runs:

- image build validation without pushing
- quality checks
- an overall pass/fail gate

The quality workflow currently includes:

- markdown linting
- YAML linting
- spelling checks
- link checks
- a repository sanity check
- licence checks

I chose to keep PR checks focused on buildability and repository quality
first. For this project, that gives fast feedback before any environment
promotion happens.

### Dev deployment

When code is merged to `main`:

1. a short SHA-based image tag is created in the form `dev-<sha>`
2. images are built and pushed to GHCR
3. the dev deployment state in the GitOps repository is updated

I chose SHA-based dev tags because they are easy to trace back to a
commit and work well for frequent integration changes.

### Staging deployment

When code is pushed to `version/*`:

1. the branch name is validated as a release branch
2. `VERSION_PATCH_NUMBER` is read
3. an RC-style tag is created in the form `<major>.<minor>.<patch>-rc-<sha>`
4. images are promoted or built
5. the staging deployment state in the GitOps repository is updated

I chose this because it makes staging look like release preparation
rather than just another copy of dev.

### Production deployment

When a semantic version tag is pushed:

1. the tag format is validated
2. the tag patch number is checked against `VERSION_PATCH_NUMBER`
3. images are promoted or built as the release tag
4. the production deployment state in the GitOps repository is updated

I chose this because it makes the production release explicit and
auditable. The version tag becomes the release marker rather than an
informal branch state.

## GitOps and runtime design

This repository is responsible for:

- application source
- Docker build inputs
- image versioning
- CI checks
- GitHub Actions automation that updates deployment state

The GitOps repository is responsible for:

- Argo CD application definitions
- deployment manifests used for CD
- environment state stored as desired configuration

Argo CD watches the GitOps repository and reconciles the EKS cluster to
match that declared state. I chose this split so image production and
cluster reconciliation stay as separate steps with a clear audit trail.

At runtime, the deployed application follows this path:

`Route 53 -> AWS load balancer -> Traefik in EKS -> application service`

TLS certificates are issued by AWS ACM. TLS is terminated at the AWS load
balancer, and Traefik then routes the request internally over HTTP
according to the host and routing rules.

Environment access is exposed with domain-based routing:

- `dev.devopsbyfelix.shop`
- `staging.devopsbyfelix.shop`
- `www.devopsbyfelix.shop`

I chose this layout because it keeps certificate handling at the AWS edge
while leaving in-cluster routing to Traefik. That separation keeps the
public entrypoint and Kubernetes routing concerns distinct.

- GitHub Actions workflows for PR, dev, staging, and production flows
- a reusable GitOps update workflow
- one-image-repository-per-service naming in GHCR
- environment promotion using branches and semantic version tags
- a delivery model where Argo CD deploys from the separate GitOps
  repository rather than from this repository directly

The upstream OpenTelemetry Demo content remains below for
application-specific usage and component details.

<!-- markdownlint-disable-next-line -->
# <img src="https://opentelemetry.io/img/logos/opentelemetry-logo-nav.png" alt="OTel logo" width="45"> OpenTelemetry Demo

[![Slack](https://img.shields.io/badge/slack-@cncf/otel/demo-brightgreen.svg?logo=slack)](https://cloud-native.slack.com/archives/C03B4CWV4DA)
[![Version](https://img.shields.io/github/v/release/open-telemetry/opentelemetry-demo?color=blueviolet)](https://github.com/open-telemetry/opentelemetry-demo/releases)
[![Commits](https://img.shields.io/github/commits-since/open-telemetry/opentelemetry-demo/latest?color=ff69b4&include_prereleases)](https://github.com/open-telemetry/opentelemetry-demo/graphs/commit-activity)
[![Downloads](https://img.shields.io/docker/pulls/otel/demo)](https://hub.docker.com/r/otel/demo)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg?color=red)](https://github.com/open-telemetry/opentelemetry-demo/blob/main/LICENSE)
[![Integration Tests](https://github.com/open-telemetry/opentelemetry-demo/actions/workflows/run-integration-tests.yml/badge.svg)](https://github.com/open-telemetry/opentelemetry-demo/actions/workflows/run-integration-tests.yml)
[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/opentelemetry-demo)](https://artifacthub.io/packages/helm/opentelemetry-helm/opentelemetry-demo)
[![FOSSA Status](https://app.fossa.com/api/projects/custom%2B162%2Fgithub.com%2Fopen-telemetry%2Fopentelemetry-demo.svg?type=shield&issueType=license)](https://app.fossa.com/projects/custom%2B162%2Fgithub.com%2Fopen-telemetry%2Fopentelemetry-demo?ref=badge_shield&issueType=license)
[![FOSSA Status](https://app.fossa.com/api/projects/custom%2B162%2Fgithub.com%2Fopen-telemetry%2Fopentelemetry-demo.svg?type=shield&issueType=security)](https://app.fossa.com/projects/custom%2B162%2Fgithub.com%2Fopen-telemetry%2Fopentelemetry-demo?ref=badge_shield&issueType=security)
[![OpenSSF Scorecard for opentelemetry-demo](https://api.scorecard.dev/projects/github.com/open-telemetry/opentelemetry-demo/badge)](https://scorecard.dev/viewer/?uri=github.com/open-telemetry/opentelemetry-demo)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/9247/badge)](https://www.bestpractices.dev/en/projects/9247)

## Welcome to the OpenTelemetry Astronomy Shop Demo

This repository contains the OpenTelemetry Astronomy Shop, a microservice-based
distributed system intended to illustrate the implementation of OpenTelemetry in
a near real-world environment.

Our goals are threefold:

- Provide a realistic example of a distributed system that can be used to
  demonstrate OpenTelemetry instrumentation and observability.
- Build a base for vendors, tooling authors, and others to extend and
  demonstrate their OpenTelemetry integrations.
- Create a living example for OpenTelemetry contributors to use for testing new
  versions of the API, SDK, and other components or enhancements.

We've already made [huge
progress](https://github.com/open-telemetry/opentelemetry-demo/blob/main/CHANGELOG.md),
and development is ongoing. We hope to represent the full feature set of
OpenTelemetry across its languages in the future.

If you'd like to help (**which we would love**), check out our [contributing
guidance](./CONTRIBUTING.md).

If you'd like to extend this demo or maintain a fork of it, read our
[fork guidance](https://opentelemetry.io/docs/demo/forking/).

## Quick start

You can be up and running with the demo in a few minutes. Check out the docs for
your preferred deployment method:

- [Docker](https://opentelemetry.io/docs/demo/docker_deployment/)
- [Kubernetes](https://opentelemetry.io/docs/demo/kubernetes_deployment/)

## Documentation

For detailed documentation, see [Demo Documentation][docs]. If you're curious
about a specific feature, the [docs landing page][docs] can point you in the
right direction.

## Demos featuring the Astronomy Shop

We welcome any vendor to fork the project to demonstrate their services and
adding a link below. The community is committed to maintaining the project and
keeping it up to date for you.

|                           |                |                                  |
|---------------------------|----------------|----------------------------------|
| [AlibabaCloud LogService] | [Grafana Labs] | [Sentry]                         |
| [Apache Doris]            | [Guance]       | [ServiceNow Cloud Observability] |
| [AppDynamics]             | [Honeycomb.io] | [SigNoz]                         |
| [Aspecto]                 | [Instana]      | [SolarWinds Observability]       |
| [Axiom]                   | [Kloudfuse]    | [Splunk]                         |
| [Axoflow]                 | [Kopai]        | [Sumo Logic]                     |
| [Azure Data Explorer]     | [Last9]        | [TelemetryHub]                   |
| [Causely]                 | [Liatrio]      | [Teletrace]                      |
| [ClickStack]              | [Logz.io]      | [Tinybird]                       |
| [Coralogix]               | [New Relic]    | [Tracetest]                      |
| [Dash0]                   | [Oodle]        | [Tsuga]                          |
| [Datadog]                 | [OpenObserve]  | [Uptrace]                        |
| [Dynatrace]               | [OpenSearch]   | [VictoriaMetrics]                |
| [Elastic]                 | [Oracle]       |                                  |
| [Google Cloud]            | [Parseable]    |                                  |

## Contributing

To get involved with the project see our [CONTRIBUTING](CONTRIBUTING.md)
documentation. Our [SIG Calls](CONTRIBUTING.md#join-a-sig-call) are every other
Wednesday at 8:30 AM PST and anyone is welcome.

### Maintainers

- [Cyrille Le Clerc](https://github.com/cyrille-leclerc), Grafana Labs
- [Juliano Costa](https://github.com/julianocosta89), Datadog
- [Pierre Tessier](https://github.com/puckpuck), Honeycomb
- [Roger Coll](https://github.com/rogercoll), Elastic

For more information about the maintainer role, see the [community repository](https://github.com/open-telemetry/community/blob/main/guides/contributor/membership.md#maintainer).

### Approvers

- [Cedric Ziel](https://github.com/cedricziel), Grafana Labs
- [Mikko Viitanen](https://github.com/mviitane), Dynatrace
- [Shenoy Pratik](https://github.com/ps48), AWS OpenSearch

For more information about the approver role, see the [community repository](https://github.com/open-telemetry/community/blob/main/guides/contributor/membership.md#approver).

### Emeritus

- [Austin Parker](https://github.com/austinlparker)
- [Carter Socha](https://github.com/cartersocha)
- [Michael Maxwell](https://github.com/mic-max)
- [Morgan McLean](https://github.com/mtwo)
- [Penghan Wang](https://github.com/wph95)
- [Reiley Yang](https://github.com/reyang)
- [Ziqi Zhao](https://github.com/fatsheep9146)

For more information about the emeritus role, see the [community repository](https://github.com/open-telemetry/community/blob/main/guides/contributor/membership.md#emeritus-maintainerapprovertriager).

### Thanks to all the people who have contributed

[![contributors](https://contributors-img.web.app/image?repo=open-telemetry/opentelemetry-demo)](https://github.com/open-telemetry/opentelemetry-demo/graphs/contributors)

[docs]: https://opentelemetry.io/docs/demo/

<!-- Links for Demos featuring the Astronomy Shop section -->

[AlibabaCloud LogService]: https://github.com/aliyun-sls/opentelemetry-demo
[AppDynamics]: https://community.splunk.com/t5/AppDynamics-Knowledge-Base/How-to-observe-Kubernetes-deployment-of-OpenTelemetry-demo-app/ta-p/741454
[Apache Doris]: https://github.com/apache/doris-opentelemetry-demo
[Aspecto]: https://github.com/aspecto-io/opentelemetry-demo
[Axiom]: https://play.axiom.co/axiom-play-qf1k/dashboards/otel.traces.otel-demo-traces
[Axoflow]: https://axoflow.com/opentelemetry-support-in-more-detail-in-axosyslog-and-syslog-ng/
[Azure Data Explorer]: https://github.com/Azure/Azure-kusto-opentelemetry-demo
[Causely]: https://github.com/causely-oss/otel-demo
[ClickStack]: https://github.com/ClickHouse/opentelemetry-demo
[Coralogix]: https://coralogix.com/blog/configure-otel-demo-send-telemetry-data-coralogix
[Dash0]: https://github.com/dash0hq/opentelemetry-demo
[Datadog]: https://docs.datadoghq.com/opentelemetry/guide/otel_demo_to_datadog
[Dynatrace]: https://www.dynatrace.com/news/blog/opentelemetry-demo-application-with-dynatrace/
[Elastic]: https://github.com/elastic/opentelemetry-demo
[Google Cloud]: https://github.com/GoogleCloudPlatform/opentelemetry-demo
[Grafana Labs]: https://github.com/grafana/opentelemetry-demo
[Guance]: https://github.com/GuanceCloud/opentelemetry-demo
[Honeycomb.io]: https://github.com/honeycombio/opentelemetry-demo
[Instana]: https://github.com/instana/opentelemetry-demo
[Kloudfuse]: https://github.com/kloudfuse/opentelemetry-demo
[Kopai]: https://github.com/kopai-app/opentelemetry-demo/tree/main/kopai
[Last9]: https://last9.io/docs/integrations-opentelemetry-demo/
[Liatrio]: https://github.com/liatrio/opentelemetry-demo
[Logz.io]: https://logz.io/learn/how-to-run-opentelemetry-demo-with-logz-io/
[New Relic]: https://github.com/newrelic/opentelemetry-demo
[Oodle]: https://blog.oodle.ai/meet-oodle-unified-and-ai-native-observability/
[OpenSearch]: https://github.com/opensearch-project/opentelemetry-demo
[OpenObserve]: https://openobserve.ai/blog/opentelemetry-astronomy-shop-demo/
[Oracle]: https://github.com/oracle-quickstart/oci-o11y-solutions/blob/main/knowledge-content/opentelemetry-demo
[Parseable]: https://www.parseable.com/blog/open-telemetry-demo-with-parseable-a-complete-observability-setup
[Sentry]: https://github.com/getsentry/opentelemetry-demo
[ServiceNow Cloud Observability]: https://docs.lightstep.com/otel/quick-start-operator#send-data-from-the-opentelemetry-demo
[SigNoz]: https://signoz.io/blog/opentelemetry-demo/
[SolarWinds Observability]: https://github.com/solarwinds/opentelemetry-demo
[Splunk]: https://github.com/signalfx/opentelemetry-demo
[Sumo Logic]: https://www.sumologic.com/blog/common-opentelemetry-demo-application/
[TelemetryHub]: https://github.com/TelemetryHub/opentelemetry-demo/tree/telemetryhub-backend
[Teletrace]: https://github.com/teletrace/opentelemetry-demo
[Tinybird]: https://github.com/tinybirdco/opentelemetry-demo
[Tracetest]: https://github.com/kubeshop/opentelemetry-demo
[Tsuga]: https://github.com/tsuga-dev/opentelemetry-demo
[Uptrace]: https://github.com/uptrace/uptrace/tree/master/example/opentelemetry-demo
[VictoriaMetrics]: https://github.com/VictoriaMetrics-Community/opentelemetry-demo
