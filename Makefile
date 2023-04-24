# use some sensible default shell settings
SHELL := /bin/bash
.SILENT:
.DEFAULT_GOAL := help

ENV ?= dev
# react variables
REACT_APP_DIR=react-app
REACT_BUILD_DIR=build

# Terraform variables
INFRA_DIR=infrastructure
TFVARS_FILE=./deployment/${ENV}.tfvars
TF_STATE_FILE = $(ENV).tfplan
TF_ARTIFACT   = .terraform/$(TF_STATE_FILE)

# docker compose for local
TF := docker-compose run --rm terraform-utils
INFRACOST := docker-compose run --rm infracost

ifeq ($(BUILDKITE), true)
	export NETWORK_NAME=$(shell uuidgen)
endif

# infracost setup
INFRACOST_ARTIFACTS_DIR=.infracost
INFRACOST_DIFF_FILE=infracost.json
INFRACOST_BASE_FILE=infracost-base.json
INFRACOST_CONFIG=.infracost.yml
BASE_BRANCH=main
ifdef $(BUILDKITE_PULL_REQUEST_BASE_BRANCH)
		BASE_BRANCH=$(BUILDKITE_PULL_REQUEST_BASE_BRANCH)
endif
CURRENT_BRANCH=$(shell git branch --show-current)


fmt:
	$(TF) terraform fmt --recursive
.PHONY: fmt

fmt_check:
	$(TF) terraform fmt -diff -check --recursive
.PHONY: fmt_check

validate: local-init
	$(TF) terraform validate
.PHONY: validate

local-init:
	$(TF) terraform init --backend=false
.PHONY: local-init

init: 
	terraform init
.PHONY: init

plan: init
ifdef BUILDKITE
	cd ${INFRA_DIR}; \
	terraform plan --var-file ${TFVARS_FILE} -out ${TF_ARTIFACT}; \
	terraform show -json ${TF_ARTIFACT} | \
	../.buildkite/scripts/recordchange_and_annotate.sh $(ENV);
else
	$(TF) terraform plan --var-file ${TFVARS_FILE} -out ${TF_ARTIFACT}
endif

.PHONY: plan 

infracost_breakdown:
	infracost breakdown \
		--config-file=$(INFRACOST_CONFIG) \
        --format=json \
        --out-file=$(INFRACOST_ARTIFACTS_DIR)/$(INFRACOST_BASE_FILE)

.PHONY: infracost_breakdown

infracost_diff:
	infracost diff \
		--config-file=$(INFRACOST_CONFIG) \
		--format=json \
		--compare-to=$(INFRACOST_ARTIFACTS_DIR)/$(INFRACOST_BASE_FILE) \
		--out-file=$(INFRACOST_ARTIFACTS_DIR)/$(INFRACOST_DIFF_FILE)

.PHONY: infracost_diff

infracost_report:
	infracost output \
		--path $(INFRACOST_ARTIFACTS_DIR)/$(INFRACOST_DIFF_FILE) \
		--show-skipped \
		--format html \
		--out-file $(INFRACOST_ARTIFACTS_DIR)/report.html

.PHONY: infracost_report

infracost_analyse:
	mkdir -p $(INFRACOST_ARTIFACTS_DIR)
	# checkout main or PR current base branch and create base cost	
	# if not in buildkite use base file for comparison
	# TODO: enable below once this PR is merged to main
	# git checkout $(BASE_BRANCH)
	infracost breakdown \
		--config-file=$(INFRACOST_CONFIG) \
        --format=json \
        --out-file=$(INFRACOST_ARTIFACTS_DIR)/$(INFRACOST_BASE_FILE)	
	# checkout current PR branch and generate diff
	git checkout $(CURRENT_BRANCH)
	infracost diff \
		--config-file=$(INFRACOST_CONFIG) \
		--format=json \
		--compare-to=$(INFRACOST_ARTIFACTS_DIR)/$(INFRACOST_BASE_FILE) \
		--out-file=$(INFRACOST_ARTIFACTS_DIR)/$(INFRACOST_DIFF_FILE)
	
	# generate html report
	infracost output \
		--path $(INFRACOST_ARTIFACTS_DIR)/$(INFRACOST_DIFF_FILE) \
		--show-skipped \
		--format html \
		--out-file $(INFRACOST_ARTIFACTS_DIR)/report.html
	# comment on buildkite PR
ifdef BUILDKITE
	infracost comment github \
		--path=$(INFRACOST_ARTIFACTS_DIR)/$(INFRACOST_DIFF_FILE) \
    	--repo=$(BUILDKITE_ORGANIZATION_SLUG)/$(BUILDKITE_PIPELINE_SLUG) \
        --pull-request=$(BUILDKITE_PULL_REQUEST) \
		--github-token=$(GITHUB_TOKEN)
        --behavior=update
endif
.PHONY: infracost_analyse

infracost_comment:
	infracost comment github \
		--path=$(INFRACOST_ARTIFACTS_DIR)/$(INFRACOST_DIFF_FILE) \
    	--repo=$(GITHUB_REPOSITORY) \
         --github-token=${{github.token}} \
        --pull-request=${{github.event.pull_request.number}} \
        --behavior=update

.PHONY: infracost_comment

apply: init unzip_react_app
ifdef BUILDKITE
	cd ${INFRA_DIR}; \
	terraform apply --auto-approve ${TF_ARTIFACT}
else
	$(TF) terraform apply --auto-approve ${TF_ARTIFACT}
endif
.PHONY: apply

list:
	$(TF) terraform state list
.PHONY: list

show:
	$(TF) terraform show -json
.PHONY: show

unlock_state: init
	$(TF) terraform force-unlock -force ${LOCK_ID}
.PHONY: unlock_state

default:
	@echo "Creates a Terraform system from a template."
	@echo "The following commands are available:"
	@echo " - validate           : runs terraform validate. This command will check and report errors within modules, attribute names, and value types."
	@echo " - fmt_check          : runs terraform format check"
	@echo " - plan               : runs terraform plan for an ENV"
	@echo " - apply              : runs terraform apply for an ENV"
