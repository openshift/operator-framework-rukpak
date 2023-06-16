#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# Know where the repo root is so we can reference things relative to it
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source bingo so we can use kustomize and yq
. "${REPO_ROOT}/.bingo/variables.env"

# We're going to do file manipulation, so let's work in a temp dir
TMP_ROOT="$(mktemp -p . -d 2>/dev/null || mktemp -d ./tmpdir.XXXXXXX)"
# Make sure to delete the temp dir when we exit
trap 'rm -rf $TMP_ROOT' EXIT

# Copy all kustomize files into a temp dir
TMP_CONFIG="${TMP_ROOT}/manifests"
cp -a "${REPO_ROOT}/manifests" "$TMP_CONFIG"

# Override core namespace to openshift-rukpak
$YQ -i '.namespace = "openshift-rukpak"' "${TMP_CONFIG}/core/kustomization.yaml"
# Override helm-provisioner namespace to openshift-rukpak
$YQ -i '.namespace = "openshift-rukpak"' "${TMP_CONFIG}/provisioners/kustomization.yaml"
# Override apis namespace to openshift-rukpak
$YQ -i '.namespace = "openshift-rukpak"' "${TMP_CONFIG}/apis/kustomization.yml"
# Override crd-validator namespace to openshift-crd-validator
$YQ -i '.namespace = "openshift-crd-validator"' "${TMP_CONFIG}/crdvalidator/kustomization.yml"

# Set the "TechPreviewNoUpgrade" for commonAnnotations 
$YQ -i '.commonAnnotations."release.openshift.io/feature-set" = "TechPreviewNoUpgrade"' "${TMP_CONFIG}/kustomization.yaml"

# Create a temp dir for manifests
TMP_MANIFEST_DIR="${TMP_ROOT}/manifests"
mkdir -p "$TMP_MANIFEST_DIR"

# Run kustomize, which emits a single yaml file
TMP_KUSTOMIZE_OUTPUT="${TMP_MANIFEST_DIR}/temp.yaml"
kubectl kustomize "${TMP_CONFIG}" -o "$TMP_KUSTOMIZE_OUTPUT"

# Use yq to split the single yaml file into 1 per document.
# Naming convention: $index-$kind-$namespace-$name. If $namespace is empty, just use the empty string.
(
  cd "$TMP_MANIFEST_DIR"

  # shellcheck disable=SC2016
  $YQ -s '$index +"-"+ (.kind|downcase) +"-"+ (.metadata.namespace // "") +"-"+ .metadata.name' temp.yaml
)

# Delete the single yaml file
rm "$TMP_KUSTOMIZE_OUTPUT"

# Delete and recreate the actual manifests directory
MANIFEST_DIR="${REPO_ROOT}/openshift/manifests"
rm -rf "${MANIFEST_DIR}"
mkdir -p "${MANIFEST_DIR}"

# Copy everything we just generated and split into the actual manifests directory
for file in "$TMP_MANIFEST_DIR"/*; do
    # Skip the directories and kustomize.yaml
    if [[ -d "$file" || "$file" =~ "kustomization.yaml" ]]; then
      continue
    fi
    cp "$file" "$MANIFEST_DIR"/
done

# Update file names to be in the format nn-$kind-$namespace-$name
(
  cd "$MANIFEST_DIR"

  for f in *; do
    # Get the numeric prefix from the filename
    index=$(echo "$f" | cut -d '-' -f 1)
    # Keep track of the full file name without the leading number and dash
    name_without_index=${f#$index-}
    # Reformat the name so the leading number is always padded to 2 digits
    #echo $index
    new_name=$(printf "%02d" "$index")-$name_without_index
    # Some file names (namely CRDs) don't end in .yml - make them
    if ! [[ "$new_name" =~ yml$ ]]; then
      new_name="$new_name".yml
    fi
    # Rename
    [[ $f != $new_name ]] || continue
    mv "$f" "$new_name"
  done
)