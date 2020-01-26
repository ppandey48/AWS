#!/bin/bash

TODAY=`date +%Y%m%d`
INSTANCE_CLASS_LIST=$POLICY_FILE_DIR/instance_types.csv

usage () {
  printf "\nUsage: migrate_database.sh [-i <iam_user_name>] [-n <db_instance_identifier>] [-u <db_admin_user>] [-p <db_admin_passwd>] [-m <yes/no> ] [-d <db_name>] [-a <account_number>] [-z <region_name>]\n"
  printf "\nOptions:\n"
  echo "  -i <iam_user_name>            = IAM user who will administer the KMS key to be used in encrypting the database"
  echo "  -n <db_instance_identifier>   = (Source) RDS Instance Identifier"
  echo "  -u <db_admin_user>            = (Source) RDS DB Admin User"
  echo "  -p <db_admin_passwd>          = (Source) RDS DB Admin Password"
  echo "  -m <yes/no>                   = Indicate if the RDS instance contains multiple databases"
  echo "  -d <db_name>                  = Specify the database name. This option can be excluded/skipped if the value of '-m' is yes"
  echo "  -a <account_number>         	= Specify the AWS account number where the resources resides"
  echo "  -z <region_name>           	= Specify the AWS Region where the resources resides"
  printf "\nNote:\nThis script requires that you have the mysql and aws cli tools installed in your server.\nPlease ensure that the security group of source and destination RDS are properly configured before running the script.\n"
}

while getopts i:n:u:p:m:d:a:z:h option
do
 case "${option}"
 in
   i) IAM_USER_NAME=${OPTARG};;
   n) DB_INST_NAME=${OPTARG};;
   u) DB_ADMIN_USER=${OPTARG};;
   p) DB_ADMIN_PASSWD=${OPTARG};;
   m) DB_MULTIPLE_OPTION=${OPTARG};;
   d) DB_NAME=${OPTARG};;
   a) ACCOUNT_NUM=${OPTARG};;
   z) REGION=${OPTARG};;
   h) usage
      exit
      ;;
 esac
done

# Describe Source Instance

echo "Getting the Source Database's Attributes..."

VPC_SECGRP_ID=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep VpcSecurityGroupId | awk -F':' '{print $2}' | sed 's/[", ]//g'`
PUBLICLY_ACCESSIBLE=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep PubliclyAccessible | awk -F':' '{print $2}' | sed 's/[", ]//g'`
MULTI_AZ=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep MultiAZ | awk -F':' '{print $2}' | sed 's/[", ]//g'`
DB_PARAM_GRP_NAME=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep DBParameterGroupName | awk -F':' '{print $2}' | sed 's/[", ]//g'`
DB_SUBNET_GRP_NAME=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep DBSubnetGroupName | awk -F':' '{print $2}' | sed 's/[", ]//g'`
VPC_ID=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep VpcId | awk -F':' '{print $2}' | sed 's/[", ]//g'`
SRC_DB_ENDPT=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep Address | awk -F':' '{print $2}' | sed 's/[", ]//g'`
DB_INSTANCE_CLASS=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep DBInstanceClass | awk -F':' '{print $2}' | sed 's/[", ]//g'`
ALLOCATED_STORAGE=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep AllocatedStorage | awk -F':' '{print $2}' | sed 's/[", ]//g'`
STORAGE_TYPE=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep StorageType | awk -F':' '{print $2}' | sed 's/[", ]//g'`
ENGINE_VERSION=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep EngineVersion | awk -F':' '{print $2}' | sed 's/[", ]//g'`
AVAILABILITY_ZONE=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep AvailabilityZone | awk -F':' '{print $2}' | sed 's/[", ]//g'`
IOPS=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME --region $REGION | grep Iops | awk -F': ' '{print $2}' | sed 's/,//g'`
DB_TAGS_LIST=`aws rds list-tags-for-resource --resource-name arn:aws:rds:$REGION:$ACCOUNT_NUM:db:$DB_INST_NAME --region $REGION | grep Value -A 1 | sed '/--/d' | sed 's/[[:space:]]//g' | awk 'NR%2{printf "%s",$0;next;}1'`

if [ "$PUBLICLY_ACCESSIBLE" == "false" ]
then
  DB_PUBLICLY_ACCESSIBLE="--no-publicly-accessible"
else
  DB_PUBLICLY_ACCESSIBLE="--publicly-accessible"
fi

if [ "$MULTI_AZ" == "false" ]
then
  DB_MULTI_AZ="--no-multi-az"
else
  DB_MULTI_AZ="--multi-az"
fi

if [ "$IOPS" == '' ]
then
  DB_IOPS=""
else
  DB_IOPS="--iops $IOPS"
fi

CHECK_INSTANCE_TYPE=`cat $INSTANCE_CLASS_LIST | grep $DB_INSTANCE_CLASS`
CHECK_INSTANCE_STAT=`echo $?`

# Create Read Replica
echo "Creating the read replica..."

CREATE_DB_READ_REPL=`aws rds create-db-instance-read-replica --db-instance-identifier $DB_INST_NAME-replica --source-db-instance-identifier $DB_INST_NAME --db-instance-class $DB_INSTANCE_CLASS --port 3306 $DB_PUBLICLY_ACCESSIBLE --storage-type $STORAGE_TYPE --copy-tags-to-snapshot --region $REGION`
CREATE_DB_READ_REPL_STAT=`echo $?`

if [ $CREATE_DB_READ_REPL_STAT -eq 0 ]
then
  echo "$DB_INST_NAME-replica has been successfully created."
else
  echo "Failed to create the DB Read Replica."
  exit
fi

# Check replication status. If successful, stop replication
check_read_replica_status () {
  REPL_DB_INSTANCE_STATUS=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME-replica --region $REGION | grep DBInstanceStatus | awk -F':' '{print $2}' | sed 's/[", ]//g'`
  REPL_DB_ENDPT=`aws rds describe-db-instances --db-instance-identifier $DB_INST_NAME-replica --region $REGION | grep Address | awk -F':' '{print $2}' | sed 's/[", ]//g'`
}

check_read_replica_status
until [ "$REPL_DB_INSTANCE_STATUS" == "available" ]
do
  echo "Waiting for the read replica database to become available..."
  sleep 20
  check_read_replica_status
done

if [ "$REPL_DB_INSTANCE_STATUS" == "available" ]
then
  sleep 5
  echo "Stopping replication in read replica..."
  EXEC_STOP_REPLICATION=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$REPL_DB_ENDPT -e 'CALL mysql.rds_stop_replication;'`
  EXEC_STOP_REPLICATION_STAT=`echo $?`

  if [ $EXEC_STOP_REPLICATION_STAT -eq 0 ]
  then
    echo "Successfully stopped replication in $DB_INST_NAME-replica."
    echo "Getting Master Log File and Position..."

    RELAY_MASTER_LOG_FILE=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$REPL_DB_ENDPT -e 'show slave status\G' | grep Relay_Master_Log_File | awk -F' ' '{print $2}'`
    RELAY_MASTER_LOG_FILE_STAT=`echo $?`
    EXEC_MASTER_LOG_POS=`mysql -u$DB_ADMIN_USER -p$DB_ADMIN_PASSWD -h$REPL_DB_ENDPT -e 'show slave status\G' | grep Exec_Master_Log_Pos | awk -F' ' '{print $2}'`
    EXEC_MASTER_LOG_POS_STAT=`echo $?`

    if [ $RELAY_MASTER_LOG_FILE_STAT -eq 0 -a $EXEC_MASTER_LOG_POS_STAT -eq 0 ]
    then
      echo Relay_Master_Log_File: $RELAY_MASTER_LOG_FILE
      echo Exec_Master_Log_Pos: $EXEC_MASTER_LOG_POS
    else
      echo "Failed to get Master Log File and Position."
      exit
    fi
  else
    echo "Failed to stop replication in $DB_INST_NAME-replica."
    exit
  fi
fi

#Create snapshot of db (read-replica)
CREATE_REPL_DB_SNAPSHOT=`aws rds create-db-snapshot --db-instance-identifier $DB_INST_NAME-replica --db-snapshot-identifier $DB_INST_NAME-replica-snapshot --region $REGION | grep Status | awk -F':' '{print$2}' | sed 's/[", ]//g'`
CREATE_DB_READ_REPL_SNAPSHOT_STAT=`echo $?`

if [ $CREATE_DB_READ_REPL_SNAPSHOT_STAT -eq 0 ]
then
    echo "Read Replica Snapshot with name $DB_INST_NAME-replica-snapshot is in progress";
else
    echo "Read Replica Snapshot creation failed";
    exit
fi

#Check Snapshot status
check_read_replica_snapshot_status () {
    CREATE_REPL_DB_SNAPSHOT_STATUS=`aws rds describe-db-snapshots --db-snapshot-identifier $DB_INST_NAME-replica-snapshot --region $REGION | grep Status | awk -F':' '{print $2}' | sed 's/[", ]//g'`
}   

check_read_replica_snapshot_status
until [ $CREATE_REPL_DB_SNAPSHOT_STATUS == "available" ]
do
    echo "Waiting for the read replica snapshot to become available...current status is $CREATE_REPL_DB_SNAPSHOT_STATUS"
    sleep 20
    check_read_replica_snapshot_status
done
