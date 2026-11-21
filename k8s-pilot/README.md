# k8s-pilot AWS 인프라

이 디렉터리는 kubeadm 실습용 EC2 세 대, 노드 간 보안 그룹, SSM용 IAM, 워커 한 대를 재부팅하는 FIS 템플릿을 정의합니다. [클러스터 조인과 Helm 배포 절차](https://github.com/pattie-assignments/k8s-pilot/blob/main/lab/README.md)는 `pattie-assignments/k8s-pilot`에 있습니다.

## 인프라 생성

`workspace-v2/terraform` 저장소 루트에서 아래 명령을 실행합니다. 이 Terraform 루트의 기본 로컬 state는 `k8s-pilot/terraform.tfstate`에 저장됩니다. `apply`는 새 실습 리소스를 생성합니다. 수동 구축한 클러스터와 연결된 state는 없습니다.

`SUBNET_ID`를 `personal-project` 계정의 서울 리전에서 인터넷 아웃바운드가 가능한 퍼블릭 서브넷 ID로 바꿉니다. 인바운드는 노드 간 통신으로 제한하며 관리 접속은 SSM을 사용합니다.

```bash
terraform -chdir=k8s-pilot init
terraform -chdir=k8s-pilot validate
terraform -chdir=k8s-pilot plan -var="subnet_id=SUBNET_ID"
terraform -chdir=k8s-pilot apply -var="subnet_id=SUBNET_ID"
terraform -chdir=k8s-pilot output -json instance_ids
terraform -chdir=k8s-pilot output -json private_ips
```

출력의 인스턴스 ID와 프라이빗 IP를 Kubernetes 조인과 배포에 사용합니다.

## FIS 워커 재부팅

대상 미리 보기로 워커 한 대가 선택되는지 확인합니다. 실제 재부팅을 실행할 때는 `--experiment-options actionsMode=skip-all`을 빼고 실행합니다.

```bash
aws --profile personal-project --region ap-northeast-2 fis start-experiment \
  --experiment-template-id "$(terraform -chdir=k8s-pilot output -raw fis_reboot_template_id)" \
  --experiment-options actionsMode=skip-all
```
