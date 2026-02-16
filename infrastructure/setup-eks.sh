#!/bin/bash
# EKS Observability Cluster - Infrastructure Setup
# This script provisions the full EKS cluster with self-managed nodes
# on AWS KodeKloud playground (account constraints apply)

set -euo pipefail

REGION="us-east-1"
CLUSTER_NAME="obs-cluster"
K8S_VERSION="1.29"
NODE_INSTANCE_TYPE="t3.medium"
NODE_COUNT=3
KEY_NAME="obs-key"

echo "=== Step 1: Create VPC ==="
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=obs-vpc}]' \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames '{"Value":true}'
echo "VPC: $VPC_ID"

echo "=== Step 2: Create Subnets ==="
PUB1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 \
  --availability-zone ${REGION}a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=obs-pub-1a},{Key=kubernetes.io/role/elb,Value=1}]' \
  --query 'Subnet.SubnetId' --output text)
PUB2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 \
  --availability-zone ${REGION}b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=obs-pub-1b},{Key=kubernetes.io/role/elb,Value=1}]' \
  --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id $PUB1 --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $PUB2 --map-public-ip-on-launch
echo "Subnets: $PUB1, $PUB2"

echo "=== Step 3: Internet Gateway ==="
IGW=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=obs-igw}]' \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC_ID
echo "IGW: $IGW"

echo "=== Step 4: Route Table ==="
RTB=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=obs-pub-rt}]' \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RTB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW
aws ec2 associate-route-table --route-table-id $RTB --subnet-id $PUB1
aws ec2 associate-route-table --route-table-id $RTB --subnet-id $PUB2
echo "Route Table: $RTB"

echo "=== Step 5: Security Group ==="
SG=$(aws ec2 create-security-group --group-name obs-sg \
  --description "Observability cluster SG" --vpc-id $VPC_ID \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SG --protocol -1 --port -1 --source-group $SG
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 6443 --cidr 0.0.0.0/0
echo "SG: $SG"

echo "=== Step 6: SSH Key Pair ==="
aws ec2 create-key-pair --key-name $KEY_NAME --query 'KeyMaterial' --output text > /tmp/${KEY_NAME}.pem
chmod 400 /tmp/${KEY_NAME}.pem
echo "Key: /tmp/${KEY_NAME}.pem"

echo "=== Step 7: IAM Roles ==="
# EKS Cluster Role
aws iam create-role --role-name eksClusterRole \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name eksClusterRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

# EKS Node Role
aws iam create-role --role-name EKSNodeRole \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name EKSNodeRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam attach-role-policy --role-name EKSNodeRole --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
aws iam attach-role-policy --role-name EKSNodeRole --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam attach-role-policy --role-name EKSNodeRole --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# EBS CSI Driver Policy (for PersistentVolumes)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
EBS_POLICY_ARN=$(aws iam create-policy --policy-name EBSCSIDriverPolicy --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["ec2:CreateVolume","ec2:DeleteVolume","ec2:DetachVolume","ec2:AttachVolume",
      "ec2:DescribeVolumes","ec2:DescribeVolumeStatus","ec2:DescribeVolumeAttribute",
      "ec2:ModifyVolume","ec2:DescribeInstances","ec2:DescribeAvailabilityZones",
      "ec2:CreateTags","ec2:DeleteTags","ec2:DescribeTags",
      "ec2:DescribeSnapshots","ec2:CreateSnapshot","ec2:DeleteSnapshot"],
    "Resource": "*"
  }]
}' --query 'Policy.Arn' --output text)
aws iam attach-role-policy --role-name EKSNodeRole --policy-arn $EBS_POLICY_ARN

# Instance Profile
aws iam create-instance-profile --instance-profile-name EKSNodeProfile
aws iam add-role-to-instance-profile --instance-profile-name EKSNodeProfile --role-name EKSNodeRole
echo "IAM roles created"

echo "=== Step 8: Create EKS Cluster ==="
aws eks create-cluster --name $CLUSTER_NAME \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/eksClusterRole \
  --resources-vpc-config subnetIds=${PUB1},${PUB2},securityGroupIds=${SG},endpointPublicAccess=true,endpointPrivateAccess=true \
  --kubernetes-version $K8S_VERSION

echo "Waiting for EKS cluster to become ACTIVE (~10 min)..."
aws eks wait cluster-active --name $CLUSTER_NAME
echo "EKS cluster ACTIVE!"

echo "=== Step 9: Configure kubectl ==="
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION

echo "=== Step 10: Get Cluster Details ==="
ENDPOINT=$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.endpoint' --output text)
CA_DATA=$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.certificateAuthority.data' --output text)
EKS_AMI=$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2/recommended/image_id --query 'Parameter.Value' --output text)
echo "Endpoint: $ENDPOINT"
echo "AMI: $EKS_AMI"

echo "=== Step 11: Launch Self-Managed Worker Nodes ==="
# KodeKloud blocks managed nodegroups and Fargate, so we use self-managed nodes
INSTANCES=$(aws ec2 run-instances \
  --image-id $EKS_AMI \
  --instance-type $NODE_INSTANCE_TYPE \
  --count $NODE_COUNT \
  --key-name $KEY_NAME \
  --security-group-ids $SG \
  --subnet-id $PUB1 \
  --iam-instance-profile Name=EKSNodeProfile \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":25,"VolumeType":"gp3"}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=obs-worker},{Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned}]" \
  --user-data "$(cat <<USERDATA
#!/bin/bash
set -ex
/etc/eks/bootstrap.sh ${CLUSTER_NAME} --apiserver-endpoint ${ENDPOINT} --b64-cluster-ca ${CA_DATA}
USERDATA
)" \
  --query 'Instances[*].InstanceId' --output text)
echo "Worker nodes: $INSTANCES"

echo "=== Step 12: Create aws-auth ConfigMap ==="
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: arn:aws:iam::${ACCOUNT_ID}:role/EKSNodeRole
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
EOF

echo "=== Step 13: Fix CA cert on nodes (if needed) ==="
# Sometimes the base64 CA gets corrupted in user-data heredoc
aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.certificateAuthority.data' --output text | base64 -d > /tmp/eks-ca.crt
sleep 60  # Wait for nodes to boot
for IP in $(aws ec2 describe-instances --instance-ids $INSTANCES --query 'Reservations[*].Instances[*].PublicIpAddress' --output text); do
  echo "Fixing CA on $IP..."
  scp -o StrictHostKeyChecking=no -i /tmp/${KEY_NAME}.pem /tmp/eks-ca.crt ec2-user@$IP:/tmp/ca.crt
  ssh -o StrictHostKeyChecking=no -i /tmp/${KEY_NAME}.pem ec2-user@$IP "sudo cp /tmp/ca.crt /etc/kubernetes/pki/ca.crt && sudo systemctl restart kubelet"
done

echo "=== Step 14: Wait for Nodes ==="
for i in $(seq 1 30); do
  READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || true)
  echo "  $READY/$NODE_COUNT nodes ready"
  [ "$READY" -ge "$NODE_COUNT" ] && break
  sleep 10
done

echo "=== Step 15: Install EBS CSI Driver ==="
kubectl apply -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=release-1.28"

# Replace default gp2 StorageClass with EBS CSI provisioner
kubectl delete sc gp2 || true
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp2
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF

echo ""
echo "========================================="
echo "EKS Cluster Ready!"
echo "========================================="
echo "Cluster: $CLUSTER_NAME"
echo "Nodes: $NODE_COUNT x $NODE_INSTANCE_TYPE"
echo "Worker IPs: $(aws ec2 describe-instances --instance-ids $INSTANCES --query 'Reservations[*].Instances[*].PublicIpAddress' --output text)"
kubectl get nodes
