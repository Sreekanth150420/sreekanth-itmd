
#!/bin/bash

######################################################################
# Format of arguments.txt
# ${1} image-id
# ${2} instance-type
# ${3} key-name
# ${4} security-group-ids
# ${5} count
# ${6} user-data file name
# ${7} availability-zone 1 (choose a)
# ${8} elb name
# ${9} target group name
# ${10} availability-zone 2 (choose b)
# ${11} auto-scaling group name
# ${12} launch template name
# ${13} db instance identifier (database name)
# ${14} db instance identifier (for read-replica), append -rpl to the database name
# ${15} min-size = 2
# ${16} max-size = 5
# ${17} desired-capacity = 3
######################################################################

######################################################################
# New tasks to add
# Note this is NOT in any order -- you need to think about this
# logically first -- perhaps write out on a piece of paper what you
# want to happen - then try to code it
######################################################################

# Create auto-scaling group
# Attach Launch Template to auto-scaling group
# Attach load-balancer to auto-scaling group
# May have to change the logic of target group
# Create RDS instance of mariadb (default values for now are fine)
# Create and Read-Replica of RDS instance
# Create all necessary wait commands

# Tasks to accomplish
echo
echo 'networking'
# Get Subnet 1 ID
# Get Subnet 2 ID
SUBNET2A=$(aws ec2 describe-subnets --output=text --query='Subnets[*].SubnetId' --filter "Name=availability-zone,Values=us-east-2a")
SUBNET2B=$(aws ec2 describe-subnets --output=text --query='Subnets[*].SubnetId' --filter "Name=availability-zone,Values=us-east-2b")
VPCID=$(aws ec2 describe-vpcs --output=text --query='Vpcs[*].VpcId')
SUBNET=$(aws ec2 describe-subnets --output=json | jq -r '.Subnets[0,1,2].SubnetId')

echo
echo 'creating RDS instances'
# Create RDS instances
# https://awscli.amazonaws.com/v2/documentation/api/latest/reference/rds/index.html
aws rds create-db-instance \
    --db-instance-identifier ${13} \
    --db-instance-class db.t3.micro \
    --engine mysql \
    --master-username wizard \
    --master-user-password cluster168 \
    --allocated-storage 20

# Add wait command for db-instance available
# https://awscli.amazonaws.com/v2/documentation/api/latest/reference/rds/wait/db-instance-available.html
echo 'waiting'
aws rds wait db-instance-available --db-instance-identifier ${13}

echo
echo 'creating RDS instances Read Replica'
aws rds create-db-instance-read-replica \
    --db-instance-identifier ${14} \
    --source-db-instance-identifier ${13}

echo
echo 'creating json lauch template'
# Create Launch Template
# Now under EC2 not auto-scaling groups
# https://awscli.amazonaws.com/v2/documentation/api/latest/reference/ec2/create-launch-template.html
# Need to convert the user-data file to a base64 string
# https://en.wikipedia.org/wiki/Base64
# https://stackoverflow.com/questions/38578528/base64-encoding-new-line
# base64 will line wrap after 76 characters -- causing the aws ec2 create-launch-template to break
# the -w 0 options will stop the line break from happening in the base64 output
#!/bin/bash

BASECONVERT=$(base64 -w 0 < ${6})

# This is the JSON object that is passed to the create template in a more readable form
# We will save it to a variable here named JSON
# Then write it out to a file -- and then attach it to the --launch-template-data option
# Otherwise we are running into issues with the dynamic bash variables

JSON="{
    \"NetworkInterfaces\": [
        {
            \"DeviceIndex\": 0,
            \"AssociatePublicIpAddress\": true,
            \"Groups\": [
                \"${4}\"
            ],
            \"DeleteOnTermination\": true
        }
    ],
    \"ImageId\": \"${1}\",
    \"InstanceType\": \"${2}\",
    \"KeyName\": \"${3}\",
    \"UserData\": \"$BASECONVERT\",
    \"Placement\": {
        \"AvailabilityZone\": \"${7}\"
    }
}"

# Redirecting the content of our JSON to a file
echo $JSON > ./config.json

aws ec2 create-launch-template \
        --launch-template-name ${12} \
        --version-description AutoScalingVersion1 \
        --launch-template-data file://config.json \
        --region us-east-2

# Launch Template Id
LAUNCHTEMPID=$(aws ec2 describe-launch-templates --output=json | jq -r '.LaunchTemplates[].LaunchTemplateId')

# AWS ec2 run-instances command no longer needed due to autoscaling group handling instance creation
# aws ec2 run-instances --image-id $1 --instance-type $2 --key-name $3 --security-group-ids $4 --count ${5} --user-data file://$6 --placement AvailabilityZone=$7
# Using jq from the command line
# INSTANCEIDS=$(aws ec2 describe-instances --output=json | jq -r '.Reservations[].Instances[].InstanceId')

# Using aws --query functions to query for the InstanceIds of only RUNNING instances, not terminated IDs
# https://docs.aws.amazon.com/cli/latest/userguide/cli-usage-filter.html
# Do not need due to the Auto Scaling Group handling instsance launch
#INSTANCEIDS=$(aws ec2 describe-instances --query 'Reservations[*].Instances[?State.Name==`running`].InstanceId')


echo
echo 'creating load LoadBalancer'
aws elbv2 create-load-balancer --name $8 --subnets $SUBNET --type application --security-groups $4
ELBARN=$(aws elbv2 describe-load-balancers --output=json | jq -r '.LoadBalancers[].LoadBalancerArn')

aws elbv2 wait load-balancer-available --load-balancer-arns $ELBARN

#https://docs.aws.amazon.com/cli/latest/reference/elbv2/create-target-group.html
TARGETARN=$(aws elbv2 create-target-group --name $9 --protocol HTTP --port 80 --target-type instance --vpc-id $VPCID --output=json | jq -r '.TargetGroups[].TargetGroupArn')



echo
echo 'creating asg'
# Create Autoscaling group ASG - needs to come after Target Group is created
# Create autoscaling group
# https://awscli.amazonaws.com/v2/documentation/api/latest/reference/autoscaling/create-auto-scaling-group.html
aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name ${11} \
    --launch-template LaunchTemplateId=$LAUNCHTEMPID \
    --target-group-arns $TARGETARN \
    --health-check-grace-period 600 \
    --min-size ${15} \
    --max-size ${16} \
    --desired-capacity ${17} \
    --availability-zones  ${7} ${10} \
    --health-check-type EC2

# https://docs.aws.amazon.com/cli/latest/reference/elbv2/register-targets.html
# For loop that goes takes every value in INSTANCEIDS and puts it in IIDS
# do not need as AutoScaling Group is linked to the target group and will handle registration
#for IIDS in $INSTANCEIDS;
#do aws elbv2 register-targets --target-group-arn $TARGETARN --targets Id=$IIDS;
#done


echo
echo 'attach targets to ELB'
#Attach target group to ELB listener
#The listener is how AWS knows that a target group is accesible, without it the next wait target-in-service will not see anything and will be stuck
# https://docs.aws.amazon.com/cli/latest/reference/elbv2/create-listener.html
aws elbv2 create-listener --load-balancer-arn $ELBARN --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TARGETARN


echo
echo 'creating waiter for registering targets'
# Create waiter for registering targets
# https://docs.aws.amazon.com/cli/latest/reference/elbv2/wait/target-in-service.html
aws elbv2 wait target-in-service --target-group-arn $TARGETARN

# Describe ELB - find the URL of the load-balancer

URL=$(aws elbv2 describe-load-balancers --output=json | jq -r  '.LoadBalancers[].DNSName')

echo
echo 'Link to DB'
echo $URL

# NOTES
# https://docs.aws.amazon.com/cli/latest/