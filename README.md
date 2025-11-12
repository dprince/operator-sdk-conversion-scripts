operator-sdk.txt

1) bash re-scaffold-operator.sh keystone-operator

** check to make sure everything scaffolds correctly. This requires the PROJECT
 had all required webhooks and API's defined correctly. If it is wrong fix
 it in the source operator directory and re-scaffold.

2) cd into keystone-operator-v4 and fix any compilation errors (use cursor)
 -- copy in the operator.SetManagerOptions code (see what I did in glance-operator)

3) $ bash sync-git-with-dir.sh keystone-operator keystone-operator-v4

4) cd keystone-operator, create a new branch: git co -b operator_sdk_1.41.1

5) remove unused tests.
 cd internal/controller && rm *_test.go; cd -
 cd internal/webhook/v1beta1/ && rm *_test.go; cd -

6) fix paths in copied over files (use cursor)
  cd test/functional
  replace: controllers with internal/controller
  replace: pkg/keystone with internal/keystone

7) Makefile changes (to the original Makefile):
 -update main.go to cmd/main.go
 -update api
 -bump KUSTOMIZE_VERSION ?= v5.6.0
 -bump OPERATOR_SDK_VERSION ?= v1.41.1
 -change tests to test

8) git add api/bases?

9) CI updates.
 .ci_operator.yaml
-  tag: ci-build-root-golang-1.24-sdk-1.31
+  tag: ci-build-root-golang-1.24-sdk-1.41.1

 zuul.d/projects.yaml
       jobs:
+        - openstack-k8s-operators-content-provider:
+            vars:
+              cifmw_install_yamls_sdk_version: v1.41.1

10) Wire up the webhooks!

11) Update Dockerfile for cmd/main.go

--------------------------
Cleanup:
 drop the <operator-name>-proxy-rolebinding, and <operator-name>-proxy-role
