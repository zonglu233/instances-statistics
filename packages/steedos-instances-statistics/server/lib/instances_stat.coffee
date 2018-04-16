schedule = Npm.require('node-schedule')

logger = new Logger 'Instances Statistics -> run'

InstancesStat = {}

#	*    *    *    *    *    *
#	┬    ┬    ┬    ┬    ┬    ┬
#	│    │    │    │    │    |
#	│    │    │    │    │    └ day of week (0 - 7) (0 or 7 is Sun)
#	│    │    │    │    └───── month (1 - 12)
#	│    │    │    └────────── day of month (1 - 31)
#	│    │    └─────────────── hour (0 - 23)
#	│    └──────────────────── minute (0 - 59)
#	└───────────────────────── second (0 - 59, OPTIONAL)

InstancesStat.rule = Meteor.settings?.cron?.instances_stat

InstancesStat.costTime = (space)->
	console.log "[#{new Date()}] run InstancesStat.costTime"
	userCostTime = new UserCostTime(space)
	userCostTime.startStat()

InstancesStat.run = (space)->
	try
		InstancesStat.costTime space
	catch  e
		console.error "InstancesStat.costTime", e

Meteor.startup ->
	if InstancesStat.rule
		schedule.scheduleJob InstancesStat.rule, Meteor.bindEnvironment(InstancesStat.run)

# InstancesStat.test('h8BomfvK7cZhyg9ub')
InstancesStat.test = (space) ->
	InstancesStat.run space

