// This file contains the logic for building our CI for Drone. The idea here is
// that we create a pipeline for all of the major tasks we need to perform
// (e.g. builds, E2E testing, conformance testing, releases). Each pipeline
// after the default builds on a previous pipeline.
// Generate with `drone jsonnet --source ./hack/drone.jsonnet --stream --format`
// Sign with `drone sign siderolabs/talos --save`

local build_container = 'autonomy/build-container:latest';
local local_registry = 'registry.dev.talos-systems.io';

local volumes = {
  dockersock: {
    pipeline: {
      name: 'dockersock',
      temp: {},
    },
    step: {
      name: $.dockersock.pipeline.name,
      path: '/var/run',
    },
  },

  outerdockersock: {
    pipeline: {
      name: 'outerdockersock',
      host: {
        path: '/var/ci-docker',
      },
    },
    step: {
      name: $.outerdockersock.pipeline.name,
      path: '/var/outer-run',
    },
  },

  docker: {
    pipeline: {
      name: 'docker',
      temp: {},
    },
    step: {
      name: $.docker.pipeline.name,
      path: '/root/.docker/buildx',
    },
  },

  kube: {
    pipeline: {
      name: 'kube',
      temp: {},
    },
    step: {
      name: $.kube.pipeline.name,
      path: '/root/.kube',
    },
  },

  dev: {
    pipeline: {
      name: 'dev',
      host: {
        path: '/dev',
      },
    },
    step: {
      name: $.dev.pipeline.name,
      path: '/dev',
    },
  },

  tmp: {
    pipeline: {
      name: 'tmp',
      temp: {
        medium: 'memory',
      },
    },
    step: {
      name: $.tmp.pipeline.name,
      path: '/tmp',
    },
  },

  ForStep(): [
    self.dockersock.step,
    self.outerdockersock.step,
    self.docker.step,
    self.kube.step,
    self.dev.step,
    self.tmp.step,
  ],

  ForPipeline(): [
    self.dockersock.pipeline,
    self.outerdockersock.pipeline,
    self.docker.pipeline,
    self.kube.pipeline,
    self.dev.pipeline,
    self.tmp.pipeline,
  ],
};

// This provides the docker service.
local docker = {
  name: 'docker',
  image: 'ghcr.io/smira/docker:20.10-dind-hacked',
  entrypoint: ['dockerd'],
  privileged: true,
  command: [
    '--dns=8.8.8.8',
    '--dns=8.8.4.4',
    '--mtu=1450',
    '--log-level=error',
  ],
  // Set resource requests to ensure that only three builds can be performed at a
  // time. We set it on the service so that we get the scheduling restricitions
  // while still allowing parallel steps.
  resources: {
    requests: {
      cpu: 12000,
      memory: '18GiB',
    },
  },
  volumes: volumes.ForStep(),
};

// Sets up the CI environment
local setup_ci = {
  name: 'setup-ci',
  image: 'autonomy/build-container:latest',
  pull: 'always',
  privileged: true,

  commands: [
    'setup-ci',
    'make external-artifacts',
  ],
  environment: {
    BUILDKIT_FLAVOR: 'cross',
  },
  volumes: volumes.ForStep(),
};

// Step standardizes the creation of build steps. The name of the step is used
// as the target when building the make command. For example, if name equals
// "test", the resulting step command will be "make test". This is done to
// encourage alignment between this file and the Makefile, and gives us a
// standardized structure that should make things easier to reason about if we
// know that each step is essentially a Makefile target.
local Step(name, image='', target='', privileged=false, depends_on=[], environment={}, extra_volumes=[], when={}) = {
  local make = if target == '' then std.format('make %s', name) else std.format('make %s', target),

  local common_env_vars = {
    PLATFORM: 'linux/amd64,linux/arm64',
  },

  name: name,
  image: if image == '' then build_container else image,
  pull: 'always',
  commands: [make],
  privileged: privileged,
  environment: common_env_vars + environment,
  volumes: volumes.ForStep() + extra_volumes,
  depends_on: [x.name for x in depends_on],
  when: when,
};

// Pipeline is a way to standardize the creation of pipelines. It supports
// using and existing pipeline as a base.
local Pipeline(name, steps=[], depends_on=[], with_docker=true, disable_clone=false, type='kubernetes') = {
  kind: 'pipeline',
  type: type,
  name: name,
  [if type == 'digitalocean' then 'token']: {
    from_secret: 'digitalocean_token',
  },
  // See https://slugs.do-api.dev/.
  [if type == 'digitalocean' then 'server']: {
    image: 'ubuntu-20-04-x64',
    size: 'c-32',
    region: 'nyc3',
  },
  [if with_docker then 'services']: [docker],
  [if disable_clone then 'clone']: {
    disable: true,
  },
  steps: steps,
  volumes: volumes.ForPipeline(),
  depends_on: [x.name for x in depends_on],
};

// Default pipeline.

local generate = Step('generate', target='generate docs', depends_on=[setup_ci]);
local check_dirty = Step('check-dirty', depends_on=[generate]);
local build = Step('build', target='talosctl-linux talosctl-darwin talosctl-freebsd talosctl-windows kernel initramfs installer imager talos _out/integration-test-linux-amd64', depends_on=[check_dirty], environment={ IMAGE_REGISTRY: local_registry, PUSH: true });
local lint = Step('lint', depends_on=[build]);
local talosctl_cni_bundle = Step('talosctl-cni-bundle', depends_on=[build, lint]);
local iso = Step('iso', target='iso', depends_on=[build], environment={ IMAGE_REGISTRY: local_registry });
local images_essential = Step('images-essential', target='images-essential', depends_on=[iso], environment={ IMAGE_REGISTRY: local_registry });
local unit_tests = Step('unit-tests', target='unit-tests unit-tests-race', depends_on=[build, lint]);
local e2e_docker = Step('e2e-docker-short', depends_on=[build, unit_tests], target='e2e-docker', environment={ SHORT_INTEGRATION_TEST: 'yes', IMAGE_REGISTRY: local_registry });
local e2e_qemu = Step('e2e-qemu-short', privileged=true, target='e2e-qemu', depends_on=[build, unit_tests, talosctl_cni_bundle], environment={ IMAGE_REGISTRY: local_registry, SHORT_INTEGRATION_TEST: 'yes' }, when={ event: ['pull_request'] });
local e2e_iso = Step('e2e-iso', privileged=true, target='e2e-iso', depends_on=[build, unit_tests, iso, talosctl_cni_bundle], when={ event: ['pull_request'] }, environment={ IMAGE_REGISTRY: local_registry });
local release_notes = Step('release-notes', depends_on=[e2e_docker, e2e_qemu]);

local coverage = {
  name: 'coverage',
  image: 'autonomy/build-container:latest',
  pull: 'always',
  environment: {
    CODECOV_TOKEN: { from_secret: 'codecov_token' },
  },
  commands: [
    '/usr/local/bin/codecov -f _out/coverage.txt -X fix',
  ],
  when: {
    event: ['pull_request'],
  },
  depends_on: [unit_tests.name],
};

local push = {
  name: 'push',
  image: 'autonomy/build-container:latest',
  pull: 'always',
  environment: {
    GHCR_USERNAME: { from_secret: 'ghcr_username' },
    GHCR_PASSWORD: { from_secret: 'ghcr_token' },
    PLATFORM: 'linux/amd64,linux/arm64',
  },
  commands: ['make push'],
  volumes: volumes.ForStep(),
  when: {
    event: {
      exclude: [
        'pull_request',
        'promote',
        'cron',
      ],
    },
  },
  depends_on: [e2e_docker.name, e2e_qemu.name],
};

local push_latest = {
  name: 'push-latest',
  image: 'autonomy/build-container:latest',
  pull: 'always',
  environment: {
    GHCR_USERNAME: { from_secret: 'ghcr_username' },
    GHCR_PASSWORD: { from_secret: 'ghcr_token' },
    PLATFORM: 'linux/amd64,linux/arm64',
  },
  commands: ['make push-latest'],
  volumes: volumes.ForStep(),
  when: {
    branch: [
      'main',
    ],
    event: [
      'push',
    ],
  },
  depends_on: [push.name],
};

local save_artifacts = {
  name: 'save-artifacts',
  image: 'autonomy/build-container:latest',
  pull: 'always',
  environment: {
    AZURE_STORAGE_ACCOUNT: { from_secret: 'az_storage_account' },
    AZURE_STORAGE_USER: { from_secret: 'az_storage_user' },
    AZURE_STORAGE_PASS: { from_secret: 'az_storage_pass' },
    AZURE_TENANT: { from_secret: 'az_tenant' },
  },
  commands: [
    'az login --service-principal -u "$${AZURE_STORAGE_USER}" -p "$${AZURE_STORAGE_PASS}" --tenant "$${AZURE_TENANT}"',
    'az storage container create --metadata ci=true -n ${CI_COMMIT_SHA}${DRONE_TAG//./-}',
    'az storage blob upload-batch --overwrite -s _out -d  ${CI_COMMIT_SHA}${DRONE_TAG//./-}'
  ],
  volumes: volumes.ForStep(),
  depends_on: [build.name, images_essential.name, iso.name, talosctl_cni_bundle.name],
};

local load_artifacts = {
  name: 'load-artifacts',
  image: 'autonomy/build-container:latest',
  pull: 'always',
  environment: {
    AZURE_STORAGE_ACCOUNT: { from_secret: 'az_storage_account' },
    AZURE_STORAGE_USER: { from_secret: 'az_storage_user' },
    AZURE_STORAGE_PASS: { from_secret: 'az_storage_pass' },
    AZURE_TENANT: { from_secret: 'az_tenant' },
  },
  commands: [
    'az login --service-principal -u "$${AZURE_STORAGE_USER}" -p "$${AZURE_STORAGE_PASS}" --tenant "$${AZURE_TENANT}"',
    'az storage blob download-batch --overwrite true -d _out -s ${CI_COMMIT_SHA}${DRONE_TAG//./-}',
    'chmod +x _out/clusterctl _out/integration-test-linux-amd64 _out/kubectl _out/kubestr _out/helm _out/cilium _out/talosctl*'
  ],
  volumes: volumes.ForStep(),
  depends_on: [setup_ci.name],
};

// builds the extensions
local extensions_build = {
  name: 'extensions-build',
  image: 'ghcr.io/siderolabs/drone-downstream:v1.2.0-33-g2306176',
  settings: {
    server: 'https://ci.dev.talos-systems.io/',
    token: {
      from_secret: 'drone_token',
    },
    repositories: [
      'siderolabs/extensions@main',
    ],
    last_successful: true,
    block: true,
    params: [
      std.format('REGISTRY=%s', local_registry),
      'PLATFORM=linux/amd64',
      'BUCKET_PATH=${CI_COMMIT_SHA}${DRONE_TAG//./-}',
      '_out/talos-metadata',
    ],
    deploy: 'e2e-talos',
  },
  depends_on: [load_artifacts.name],
};

// here we need to wait for the extensions build to finish
local extensions_artifacts = load_artifacts {
  name: 'extensions-artifacts',
  commands: [
    'az login --service-principal -u "$${AZURE_STORAGE_USER}" -p "$${AZURE_STORAGE_PASS}" --tenant "$${AZURE_TENANT}"',
    'az storage blob download -f _out/extensions-metadata -n extensions-metadata -c ${CI_COMMIT_SHA}${DRONE_TAG//./-}',
  ],
  depends_on: [setup_ci.name, extensions_build.name],
};

// generates the extension list patch manifest
local extensions_patch_manifest = {
  name: 'extensions-patch-manifest',
  image: 'autonomy/build-container:latest',
  pull: 'always',
  commands: [
    // create a patch file to pass to the downstream build
    // ignore nvidia extensions, testing nvidia extensions needs a machine with nvidia graphics card
    // ignore nut extensions, needs extra config files
    'jq -R < _out/extensions-metadata | jq -s \'[{"op":"add","path":"/machine/install/extensions","value":[{"image": map(select(. | contains("nvidia") or contains("nut") | not)) | .[]}]},{"op":"add","path":"/machine/sysctls","value":{"user.max_user_namespaces": "11255"}}]\' > _out/extensions-patch.json',
    'cat _out/extensions-patch.json',
  ],
  depends_on: [extensions_artifacts.name],
};

local default_steps = [
  setup_ci,
  generate,
  check_dirty,
  build,
  lint,
  talosctl_cni_bundle,
  iso,
  images_essential,
  unit_tests,
  save_artifacts,
  coverage,
  e2e_iso,
  e2e_qemu,
  e2e_docker,
  release_notes,
  push,
  push_latest,
];

local default_trigger = {
  trigger: {
    event: {
      exclude: [
        'tag',
        'promote',
        'cron',
      ],
    },
    branch: {
      exclude: [
        'renovate/*',
        'dependabot/*',
      ],
    },
  },
};

local cron_trigger(schedules) = {
  trigger: {
    cron: {
      include: schedules,
    },
  },
};

local default_pipeline = Pipeline('default', default_steps) + default_trigger;

local default_cron_pipeline = Pipeline('cron-default', default_steps) + cron_trigger(['thrice-daily', 'nightly']);

// Full integration pipeline.

local default_pipeline_steps = [
  setup_ci,
  load_artifacts,
];

local integration_qemu = Step('e2e-qemu', privileged=true, depends_on=[load_artifacts], environment={ IMAGE_REGISTRY: local_registry });

local build_race = Step('build-race', target='initramfs installer', depends_on=[load_artifacts], environment={ IMAGE_REGISTRY: local_registry, PUSH: true, TAG_SUFFIX: '-race', WITH_RACE: '1', PLATFORM: 'linux/amd64' });
local integration_qemu_race = Step('e2e-qemu-race', target='e2e-qemu', privileged=true, depends_on=[build_race], environment={ IMAGE_REGISTRY: local_registry, TAG_SUFFIX: '-race' });

local integration_provision_tests_prepare = Step('provision-tests-prepare', privileged=true, depends_on=[load_artifacts]);
local integration_provision_tests_track_0 = Step('provision-tests-track-0', privileged=true, depends_on=[integration_provision_tests_prepare], environment={ IMAGE_REGISTRY: local_registry });
local integration_provision_tests_track_1 = Step('provision-tests-track-1', privileged=true, depends_on=[integration_provision_tests_prepare], environment={ IMAGE_REGISTRY: local_registry });
local integration_provision_tests_track_2 = Step('provision-tests-track-2', privileged=true, depends_on=[integration_provision_tests_prepare], environment={ IMAGE_REGISTRY: local_registry });

local integration_extensions = Step('e2e-extensions', target='e2e-qemu', privileged=true, depends_on=[extensions_patch_manifest], environment={
  SHORT_INTEGRATION_TEST: 'yes',
  QEMU_MEMORY_WORKERS: '3072',
  WITH_CONFIG_PATCH_WORKER: '@_out/extensions-patch.json',
  WITH_TEST: 'run_extensions_test',
  IMAGE_REGISTRY: local_registry,
});
local integration_cilium = Step('e2e-cilium', target='e2e-qemu', privileged=true, depends_on=[load_artifacts], environment={
  SHORT_INTEGRATION_TEST: 'yes',
  WITH_SKIP_BOOT_PHASE_FINISHED_CHECK: 'yes',
  CUSTOM_CNI_NAME: 'cilium',
  QEMU_WORKERS: '2',
  WITH_CONFIG_PATCH: '[{"op": "add", "path": "/cluster/network", "value": {"cni": {"name": "none"}}}]',
  IMAGE_REGISTRY: local_registry,
});
local integration_cilium_strict = Step('e2e-cilium-strict', target='e2e-qemu', privileged=true, depends_on=[integration_cilium], environment={
  SHORT_INTEGRATION_TEST: 'yes',
  WITH_SKIP_BOOT_PHASE_FINISHED_CHECK: 'yes',
  CUSTOM_CNI_NAME: 'cilium',
  QEMU_WORKERS: '2',
  CILIUM_INSTALL_TYPE: 'strict',
  WITH_CONFIG_PATCH: '[{"op": "add", "path": "/cluster/network", "value": {"cni": {"name": "none"}}}, {"op": "add", "path": "/cluster/proxy", "value": {"disabled": true}}]',
  IMAGE_REGISTRY: local_registry,
});
local integration_canal_reset = Step('e2e-canal-reset', target='e2e-qemu', privileged=true, depends_on=[load_artifacts], environment={
  INTEGRATION_TEST_RUN: 'TestIntegration/api.ResetSuite/TestResetWithSpec',
  CUSTOM_CNI_URL: 'https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/canal.yaml',
  REGISTRY: local_registry,
});
local integration_bios_cgroupsv1 = Step('e2e-bios-cgroupsv1', target='e2e-qemu', privileged=true, depends_on=[integration_canal_reset], environment={
  SHORT_INTEGRATION_TEST: 'yes',
  WITH_UEFI: 'false',
  IMAGE_REGISTRY: local_registry,
  WITH_CONFIG_PATCH: '[{"op": "add", "path": "/machine/install/extraKernelArgs/-", "value": "talos.unified_cgroup_hierarchy=0"}]',  // use cgroupsv1
});
local integration_disk_image = Step('e2e-disk-image', target='e2e-qemu', privileged=true, depends_on=[integration_bios_cgroupsv1], environment={
  SHORT_INTEGRATION_TEST: 'yes',
  USE_DISK_IMAGE: 'true',
  IMAGE_REGISTRY: local_registry,
  WITH_DISK_ENCRYPTION: 'true',
});
local integration_control_plane_port = Step('e2e-cp-port', target='e2e-qemu', privileged=true, depends_on=[integration_disk_image], environment={
  SHORT_INTEGRATION_TEST: 'yes',
  REGISTRY: local_registry,
  WITH_CONTROL_PLANE_PORT: '443',
});
local integration_no_cluster_discovery = Step('e2e-no-cluster-discovery', target='e2e-qemu', privileged=true, depends_on=[integration_control_plane_port], environment={
  SHORT_INTEGRATION_TEST: 'yes',
  WITH_CLUSTER_DISCOVERY: 'false',
  IMAGE_REGISTRY: local_registry,
});
local integration_kubespan = Step('e2e-kubespan', target='e2e-qemu', privileged=true, depends_on=[integration_no_cluster_discovery], environment={
  SHORT_INTEGRATION_TEST: 'yes',
  WITH_CLUSTER_DISCOVERY: 'true',
  IMAGE_REGISTRY: local_registry,
  WITH_CONFIG_PATCH: '[{"op": "replace", "path": "/cluster/discovery/registries/kubernetes/disabled", "value": false}]',  // use Kubernetes discovery backend
});
local integration_default_hostname = Step('e2e-default-hostname', target='e2e-qemu', privileged=true, depends_on=[integration_kubespan], environment={
  // regression test: make sure Talos works in maintenance mode when no hostname is set
  SHORT_INTEGRATION_TEST: 'yes',
  IMAGE_REGISTRY: local_registry,
  VIA_MAINTENANCE_MODE: 'true',
  DISABLE_DHCP_HOSTNAME: 'true',
});

local integration_qemu_encrypted_vip = Step('e2e-encrypted-vip', target='e2e-qemu', privileged=true, depends_on=[load_artifacts], environment={
  WITH_DISK_ENCRYPTION: 'true',
  WITH_VIRTUAL_IP: 'true',
  IMAGE_REGISTRY: local_registry,
});

local integration_qemu_csi = Step('e2e-csi', target='e2e-qemu', privileged=true, depends_on=[load_artifacts], environment={
  IMAGE_REGISTRY: local_registry,
  SHORT_INTEGRATION_TEST: 'yes',
  QEMU_WORKERS: '3',
  QEMU_CPUS_WORKERS: '4',
  QEMU_MEMORY_WORKERS: '5120',
  QEMU_EXTRA_DISKS: '1',
  QEMU_EXTRA_DISKS_SIZE: '12288',
  WITH_TEST: 'run_csi_tests',
});

local integration_images = Step('images', target='images', depends_on=[load_artifacts], environment={ IMAGE_REGISTRY: local_registry });
local integration_sbcs = Step('sbcs', target='sbcs', depends_on=[integration_images], environment={ IMAGE_REGISTRY: local_registry });

local push_edge = {
  name: 'push-edge',
  image: 'autonomy/build-container:latest',
  pull: 'always',
  environment: {
    GHCR_USERNAME: { from_secret: 'ghcr_username' },
    GHCR_PASSWORD: { from_secret: 'ghcr_token' },
  },
  commands: ['make push-edge'],
  volumes: volumes.ForStep(),
  when: {
    cron: [
      'nightly',
    ],
  },
  depends_on: [
    integration_qemu.name,
  ],
};

local integration_trigger(names) = {
  trigger: {
    target: {
      include: ['integration'] + names,
    },
  },
};

local integration_pipelines = [
  // regular pipelines, triggered on promote events
  Pipeline('integration-qemu', default_pipeline_steps + [integration_qemu, push_edge]) + integration_trigger(['integration-qemu']),
  Pipeline('integration-provision-0', default_pipeline_steps + [integration_provision_tests_prepare, integration_provision_tests_track_0]) + integration_trigger(['integration-provision', 'integration-provision-0']),
  Pipeline('integration-provision-1', default_pipeline_steps + [integration_provision_tests_prepare, integration_provision_tests_track_1]) + integration_trigger(['integration-provision', 'integration-provision-1']),
  Pipeline('integration-provision-2', default_pipeline_steps + [integration_provision_tests_prepare, integration_provision_tests_track_2]) + integration_trigger(['integration-provision', 'integration-provision-2']),
  Pipeline('integration-misc', default_pipeline_steps + [
    integration_canal_reset,
    integration_bios_cgroupsv1,
    integration_disk_image,
    integration_control_plane_port,
    integration_no_cluster_discovery,
    integration_kubespan,
    integration_default_hostname,
  ]) + integration_trigger(['integration-misc']),
  Pipeline('integration-extensions', default_pipeline_steps + [extensions_build, extensions_artifacts, extensions_patch_manifest, integration_extensions]) + integration_trigger(['integration-extensions']),
  Pipeline('integration-cilium', default_pipeline_steps + [integration_cilium, integration_cilium_strict]) + integration_trigger(['integration-cilium']),
  Pipeline('integration-qemu-encrypted-vip', default_pipeline_steps + [integration_qemu_encrypted_vip]) + integration_trigger(['integration-qemu-encrypted-vip']),
  Pipeline('integration-qemu-race', default_pipeline_steps + [build_race, integration_qemu_race]) + integration_trigger(['integration-qemu-race']),
  Pipeline('integration-qemu-csi', default_pipeline_steps + [integration_qemu_csi]) + integration_trigger(['integration-qemu-csi']),
  Pipeline('integration-images', default_pipeline_steps + [integration_images, integration_sbcs]) + integration_trigger(['integration-images']),

  // cron pipelines, triggered on schedule events
  Pipeline('cron-integration-qemu', default_pipeline_steps + [integration_qemu, push_edge], [default_cron_pipeline]) + cron_trigger(['thrice-daily', 'nightly']),
  Pipeline('cron-integration-provision-0', default_pipeline_steps + [integration_provision_tests_prepare, integration_provision_tests_track_0], [default_cron_pipeline]) + cron_trigger(['thrice-daily', 'nightly']),
  Pipeline('cron-integration-provision-1', default_pipeline_steps + [integration_provision_tests_prepare, integration_provision_tests_track_1], [default_cron_pipeline]) + cron_trigger(['thrice-daily', 'nightly']),
  Pipeline('cron-integration-provision-2', default_pipeline_steps + [integration_provision_tests_prepare, integration_provision_tests_track_2], [default_cron_pipeline]) + cron_trigger(['thrice-daily', 'nightly']),
  Pipeline('cron-integration-misc', default_pipeline_steps + [
    integration_canal_reset,
    integration_bios_cgroupsv1,
    integration_disk_image,
    integration_control_plane_port,
    integration_no_cluster_discovery,
    integration_kubespan,
    integration_default_hostname,
  ], [default_cron_pipeline]) + cron_trigger(['thrice-daily', 'nightly']),
  Pipeline('cron-integration-extensions', default_pipeline_steps + [extensions_build, extensions_artifacts, extensions_patch_manifest, integration_extensions], [default_cron_pipeline]) + cron_trigger(['nightly']),
  Pipeline('cron-integration-cilium', default_pipeline_steps + [integration_cilium, integration_cilium_strict], [default_cron_pipeline]) + cron_trigger(['nightly']),
  Pipeline('cron-integration-qemu-encrypted-vip', default_pipeline_steps + [integration_qemu_encrypted_vip], [default_cron_pipeline]) + cron_trigger(['thrice-daily', 'nightly']),
  Pipeline('cron-integration-qemu-race', default_pipeline_steps + [build_race, integration_qemu_race], [default_cron_pipeline]) + cron_trigger(['nightly']),
  Pipeline('cron-integration-qemu-csi', default_pipeline_steps + [integration_qemu_csi], [default_cron_pipeline]) + cron_trigger(['nightly']),
  Pipeline('cron-integration-images', default_pipeline_steps + [integration_images, integration_sbcs], [default_cron_pipeline]) + cron_trigger(['nightly']),
];


// E2E pipeline.

local creds_env_vars = {
  AWS_ACCESS_KEY_ID: { from_secret: 'aws_access_key_id' },
  AWS_SECRET_ACCESS_KEY: { from_secret: 'aws_secret_access_key' },
  AWS_SVC_ACCT: { from_secret: 'aws_svc_acct' },
  AZURE_SVC_ACCT: { from_secret: 'azure_svc_acct' },
  // TODO(andrewrynhard): Rename this to the GCP convention.
  GCE_SVC_ACCT: { from_secret: 'gce_svc_acct' },
  PACKET_AUTH_TOKEN: { from_secret: 'packet_auth_token' },
  GITHUB_TOKEN: { from_secret: 'ghcr_token' },  // Use GitHub API token to avoid rate limiting on CAPI -> GitHub calls.
};

local capi_docker = Step('e2e-docker', depends_on=[load_artifacts], target='e2e-docker', environment={
  IMAGE_REGISTRY: local_registry,
  SHORT_INTEGRATION_TEST: 'yes',
  INTEGRATION_TEST_RUN: 'XXX',
});
local e2e_capi = Step('e2e-capi', depends_on=[capi_docker], environment=creds_env_vars);
local e2e_aws = Step('e2e-aws', depends_on=[e2e_capi], environment=creds_env_vars);
local e2e_azure = Step('e2e-azure', depends_on=[e2e_capi], environment=creds_env_vars);
local e2e_gcp = Step('e2e-gcp', depends_on=[e2e_capi], environment=creds_env_vars);

local e2e_trigger(names) = {
  trigger: {
    target: {
      include: ['e2e'] + names,
    },
  },
};

local e2e_pipelines = [
  // regular pipelines, triggered on promote events
  Pipeline('e2e-aws', default_pipeline_steps + [capi_docker, e2e_capi, e2e_aws]) + e2e_trigger(['e2e-aws']),
  Pipeline('e2e-gcp', default_pipeline_steps + [capi_docker, e2e_capi, e2e_gcp]) + e2e_trigger(['e2e-gcp']),

  // cron pipelines, triggered on schedule events
  Pipeline('cron-e2e-aws', default_pipeline_steps + [capi_docker, e2e_capi, e2e_aws], [default_cron_pipeline]) + cron_trigger(['thrice-daily', 'nightly']),
  Pipeline('cron-e2e-gcp', default_pipeline_steps + [capi_docker, e2e_capi, e2e_gcp], [default_cron_pipeline]) + cron_trigger(['thrice-daily', 'nightly']),
];

// Conformance pipeline.

local conformance_k8s_qemu = Step('conformance-k8s-qemu', target='e2e-qemu', privileged=true, depends_on=[load_artifacts], environment={
  QEMU_WORKERS: '2',  // conformance test requires >=2 workers
  QEMU_CPUS: '4',  // conformance test in parallel runs with number of CPUs
  TEST_MODE: 'fast-conformance',
  IMAGE_REGISTRY: local_registry,
});

local conformance_trigger(names) = {
  trigger: {
    target: {
      include: ['conformance'] + names,
    },
  },
};

local conformance_pipelines = [
  // regular pipelines, triggered on promote events
  Pipeline('conformance-qemu', default_pipeline_steps + [conformance_k8s_qemu]) + conformance_trigger(['conformance-qemu']),

  // cron pipelines, triggered on schedule events
  Pipeline('cron-conformance-qemu', default_pipeline_steps + [conformance_k8s_qemu], [default_cron_pipeline]) + cron_trigger(['nightly']),
];

// Release pipeline.

local cloud_images = Step('cloud-images', depends_on=[e2e_docker, e2e_qemu], environment=creds_env_vars);
local images = Step('images', target='images', depends_on=[iso, images_essential], environment={ IMAGE_REGISTRY: local_registry });
local sbcs = Step('sbcs', target='sbcs', depends_on=[images], environment={ IMAGE_REGISTRY: local_registry });

// TODO(andrewrynhard): We should run E2E tests on a release.
local release = {
  name: 'release',
  image: 'plugins/github-release',
  settings: {
    api_key: { from_secret: 'github_token' },
    draft: true,
    note: '_out/RELEASE_NOTES.md',
    files: [
      '_out/aws-amd64.tar.gz',
      '_out/aws-arm64.tar.gz',
      '_out/azure-amd64.tar.gz',
      '_out/azure-arm64.tar.gz',
      '_out/cloud-images.json',
      '_out/digital-ocean-amd64.raw.gz',
      '_out/digital-ocean-arm64.raw.gz',
      '_out/exoscale-amd64.qcow2',
      '_out/exoscale-arm64.qcow2',
      '_out/gcp-amd64.tar.gz',
      '_out/gcp-arm64.tar.gz',
      '_out/hcloud-amd64.raw.xz',
      '_out/hcloud-arm64.raw.xz',
      '_out/initramfs-amd64.xz',
      '_out/initramfs-arm64.xz',
      '_out/metal-amd64.tar.gz',
      '_out/metal-arm64.tar.gz',
      '_out/metal-rpi_4-arm64.img.xz',
      '_out/metal-rpi_generic-arm64.img.xz',
      '_out/metal-rockpi_4-arm64.img.xz',
      '_out/metal-rockpi_4c-arm64.img.xz',
      '_out/metal-rock64-arm64.img.xz',
      '_out/metal-pine64-arm64.img.xz',
      '_out/metal-bananapi_m64-arm64.img.xz',
      '_out/metal-libretech_all_h3_cc_h5-arm64.img.xz',
      '_out/metal-jetson_nano-arm64.img.xz',
      '_out/metal-nanopi_r4s-arm64.img.xz',
      '_out/nocloud-amd64.raw.xz',
      '_out/nocloud-arm64.raw.xz',
      '_out/openstack-amd64.tar.gz',
      '_out/openstack-arm64.tar.gz',
      '_out/oracle-amd64.qcow2.xz',
      '_out/oracle-arm64.qcow2.xz',
      '_out/scaleway-amd64.raw.xz',
      '_out/scaleway-arm64.raw.xz',
      '_out/talos-amd64.iso',
      '_out/talos-arm64.iso',
      '_out/talosctl-cni-bundle-amd64.tar.gz',
      '_out/talosctl-cni-bundle-arm64.tar.gz',
      '_out/talosctl-darwin-amd64',
      '_out/talosctl-darwin-arm64',
      '_out/talosctl-freebsd-amd64',
      '_out/talosctl-freebsd-arm64',
      '_out/talosctl-linux-amd64',
      '_out/talosctl-linux-arm64',
      '_out/talosctl-linux-armv7',
      '_out/talosctl-windows-amd64.exe',
      '_out/upcloud-amd64.raw.xz',
      '_out/upcloud-arm64.raw.xz',
      '_out/vmware-amd64.ova',
      '_out/vmware-arm64.ova',
      '_out/vmlinuz-amd64',
      '_out/vmlinuz-arm64',
      '_out/vultr-amd64.raw.xz',
      '_out/vultr-arm64.raw.xz',
    ],
    checksum: ['sha256', 'sha512'],
  },
  when: {
    event: ['tag'],
  },
  depends_on: [build.name, cloud_images.name, talosctl_cni_bundle.name, images.name, sbcs.name, iso.name, push.name, release_notes.name],
};

local release_steps = default_steps + [
  images,
  sbcs,
  cloud_images,
  release,
];

local release_trigger = {
  trigger: {
    event: [
      'tag',
    ],
    ref: {
      exclude: [
        'refs/tags/pkg/**',
      ],
    },
  },
};

local release_pipeline = Pipeline('release', release_steps) + release_trigger;

// Notify pipeline.

local notify = {
  name: 'slack',
  image: 'plugins/slack',
  settings: {
    webhook: { from_secret: 'slack_webhook' },
    channel: 'proj-talos-maintainers',
    link_names: true,
    template: '{{#if build.pull }}\n*{{#success build.status}}✓ Success{{else}}✕ Fail{{/success}}*: {{ repo.owner }}/{{ repo.name }} - <https://github.com/{{ repo.owner }}/{{ repo.name }}/pull/{{ build.pull }}|Pull Request #{{ build.pull }}>\n{{else}}\n*{{#success build.status}}✓ Success{{else}}✕ Fail{{/success}}: {{ repo.owner }}/{{ repo.name }} - Build #{{ build.number }}* (type: `{{ build.event }}`)\n{{/if}}\nCommit: <https://github.com/{{ repo.owner }}/{{ repo.name }}/commit/{{ build.commit }}|{{ truncate build.commit 8 }}>\nBranch: <https://github.com/{{ repo.owner }}/{{ repo.name }}/commits/{{ build.branch }}|{{ build.branch }}>\nAuthor: {{ build.author }}\n<{{ build.link }}|Visit build page>',
  },
  when: {
    status: [
      'success',
      'failure',
    ],
  },
};

local notify_steps = [notify];

local notify_trigger = {
  trigger: {
    status: ['success', 'failure'],
    branch: {
      exclude: [
        'renovate/*',
        'dependabot/*',
      ],
    },
  },
};

local notify_pipeline = Pipeline('notify', notify_steps, [default_pipeline, release_pipeline] + integration_pipelines + e2e_pipelines + conformance_pipelines, false, true) + notify_trigger;

// Final configuration file definition.

[
  default_pipeline,
  default_cron_pipeline,
  release_pipeline,
] + integration_pipelines + e2e_pipelines + conformance_pipelines + [
  notify_pipeline,
]
