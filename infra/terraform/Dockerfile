# Stage 1: grab a pinned Terraform binary
FROM hashicorp/terraform:1.9.5 AS tf

# Stage 2: Azure CLI base (Azure Linux / CBL-Mariner)
# You can pin more tightly if you like: :2.74.0-azurelinux3.0
FROM mcr.microsoft.com/azure-cli:2.74.0

# Add Terraform from stage 1
COPY --from=tf /bin/terraform /usr/local/bin/terraform

# Install utilities using CBL-Mariner's package manager (tdnf)
# Note: "openssh-clients" is the RPM-world package name
RUN tdnf install -y \
      git jq make openssh-clients ca-certificates curl \
    && tdnf clean all

WORKDIR /work
