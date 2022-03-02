DISTDIR := $(PWD)/dist/

PROJECT      ?=publish
REPO_NAME    ?=$(PROJECT)/pie-php7.4
UBUNTU_VER   ?=20.04
REPO_URI     ?=$(shell aws ecr describe-repositories --repository-names $(REPO_NAME) --output text --query 'repositories[].repositoryUri' --region us-east-2)
REPO_URI_BAK ?=$(shell aws ecr describe-repositories --repository-names $(REPO_NAME) --output text --query 'repositories[].repositoryUri' --region us-east-1)

.PHONY: clean ecr-login image-build image-push-latest image-push-dev image-push-test image-push-prod

clean:
	rm -fr -- .venv || :
	rm -fr -- "$(DISTDIR)" || :

ecr-login:
	_repo='$(REPO_URI)'; aws ecr get-login-password --region us-east-2 | docker login --username AWS --password-stdin $${_repo%%/*}
	_repo='$(REPO_URI_BAK)'; aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $${_repo%%/*}

image-build:
	[ -e "$(DISTDIR)" ] || mkdir -p "$(DISTDIR)"
	docker build -t $(REPO_NAME):latest --iidfile "$(DISTDIR)/base.image-id" .
	docker tag $(REPO_NAME):latest $(REPO_NAME):latest-ubuntu
	docker tag $(REPO_NAME):latest $(REPO_NAME):latest-ubuntu$(UBUNTU_VER)
	if [ -n "$(REPO_URI)" ]; then \
		docker tag $(REPO_NAME):latest $(REPO_URI):latest; \
		docker tag $(REPO_NAME):latest $(REPO_URI):latest-ubuntu; \
		docker tag $(REPO_NAME):latest $(REPO_URI):latest-ubuntu$(UBUNTU_VER); \
	fi
	if [ -n "$(REPO_URI_BAK)" ]; then \
		docker tag $(REPO_NAME):latest $(REPO_URI_BAK):latest; \
		docker tag $(REPO_NAME):latest $(REPO_URI_BAK):latest-ubuntu; \
		docker tag $(REPO_NAME):latest $(REPO_URI_BAK):latest-ubuntu$(UBUNTU_VER); \
	fi

image-push-latest:
	for _repo in $(REPO_URI) $(REPO_URI_BAK); do \
		docker push $$_repo:latest; \
		sleep 10; \
	done

image-push-dev:
	for _repo in $(REPO_URI) $(REPO_URI_BAK); do \
		docker tag $(REPO_NAME):latest $$_repo:dev; \
		docker push $$_repo:dev; \
		sleep 10; \
	done

image-push-test:
	for _repo in $(REPO_URI) $(REPO_URI_BAK); do \
		docker tag $(REPO_NAME):latest $$_repo:test; \
		docker push $$_repo:test; \
		sleep 10; \
	done

image-push-prod:
	for _repo in $(REPO_URI) $(REPO_URI_BAK); do \
		docker tag $(REPO_NAME):latest $$_repo:prod; \
		docker push $$_repo:prod; \
		sleep 10; \
	done
