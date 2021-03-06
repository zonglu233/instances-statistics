rem ##### localhost
rem set DB_SERVER=localhost

rem ##### 21 server
set DB_SERVER=192.168.0.21

set MONGO_URL=mongodb://%DB_SERVER%/steedos
set MONGO_OPLOG_URL=mongodb://%DB_SERVER%/local
set MULTIPLE_INSTANCES_COLLECTION_NAME=workflow_instances

set ROOT_URL=http://127.0.0.1:3089/
meteor run --port 3089 --settings settings.json