logger = new Logger 'Instances Statistics -> UserCostTime'

# space: 工作区ID
UserCostTime = (space) ->
	@space = space
	return

UserCostTime::startStat = () ->
	console.log 'UserCostTime.startStat()'

	spaceId = @space

	ins_approves = new Array()

	# 开始日期是当月的一号
	now_date = new Date()
	now_year = now_date.getFullYear()
	now_month = now_date.getMonth()+1
	start_date = new Date("'" + now_year + "-" + now_month + "'")
	# 结束日期是当月统计的当天
	end_date = now_date

	query = {}

	query.space = spaceId
	
	# 不是 已删除 的
	query.is_deleted = false

	# 排除 取消申请 的
	query.final_decision = {$ne: "terminated"}

	# completed	已完成
	# pending	进行中
	query.state = {$in: ["pending", "completed"]}

	space_users = db.space_users.find({space: spaceId},{fields: {user: 1}}).fetch()

	space_user_ids = space_users.map((m)->return m.user)

	aggregate = (pipeline, ins_approves, cb) ->
		# aggregate聚合
		cursor = db.instances.rawCollection().aggregate pipeline, {cursor: {}}

		cursor.on 'data', (doc) ->

			doc.is_finished = doc._id.is_finished || false

			ins_approves.push(doc);

		cursor.once('end', () ->
			cb();
		)

	async_aggregate = Meteor.wrapAsync(aggregate)

	pipeline = [
				{
					$match: query
				},
				{
					# $project:修改输入文档的结构。可以用来重命名、增加或删除域，也可以用于创建计算结果以及嵌套文档。
					$project:{
						"_approve": '$traces.approves'
					}
				},
				{
					# $unwind:将数组拆分，每条包含数组中的一个值。
					$unwind: "$_approve"
				},
				{
					# $unwind:将数组拆分，每条包含数组中的一个值。
					$unwind: "$_approve"
				},
				{
					# $match:过滤   draft:表示草稿
					$match: {
						# 不包括 草稿、分发和转发
						"_approve.type" : {$nin: ["draft", "distribute", "forward"]},
						# 查找当前工作区用户的申请单
						"_approve.handler" : {$in: space_user_ids},
						# 或：
						$or:[
							# 审批未结束的申请单
							{"_approve.is_finished": false}
							# 审批结束的申请单，且结束日期是在[开始，结束]区间
							$and:[
								{"_approve.finish_date": {$gte: start_date}},
								{"_approve.finish_date": {$lte: end_date}}
							]
						]
					}
				},
				{
					# $group:将集合中的文档分组，可用于统计结果。
					$group : {
						_id : {
							"handler": "$_approve.handler",
							"is_finished": "$_approve.is_finished"
						}
						# 当月已处理总耗时
						month_finished_time: {
							$sum: "$_approve.cost_time"
						},
						# 当月审批总数
						month_finished_count: {
							$sum: 1
						},
						# 审批开始时间
						itemsSold: {
							$push:  { start_date: "$_approve.start_date"}
						}
					}
				}
			]


	console.time("async_aggregate_cost_time")

	# 管道在Unix和Linux中一般用于将当前命令的输出结果作为下一个命令的参数。
	cursor = async_aggregate(pipeline, ins_approves)

	# console.log "ins_approves.length", ins_approves.length

	if ins_approves.length > 0

		ins_approves_group = _.groupBy ins_approves, "is_finished"

		# 审批完成的步骤
		finished_approves = ins_approves_group[true]

		# 待审批的步骤
		inbox_approves = ins_approves_group[false]

		# 遍历已处理的列表
		finished_approves.forEach (finished_approve)->

			inbox_approve = _.find(inbox_approves, (item ,index)->
				# console.log '			item',item._id
				# 待审批步骤里面的人员和审批完成步骤里面的人员一致
				if item._id?.handler == finished_approve._id?.handler
					inbox_approves.splice(index,1)
					return item
			)

			# 本月待处理数量
			finished_approve.inbox_count = inbox_approve?.month_finished_count||0

			# console.log finished_approve.inbox_count

			delete finished_approve.is_finished	# 本来就是已完成

			finished_approve.itemsSold = inbox_approve?.itemsSold

		# 遍历剩余未处理的列表
		inbox_approves?.forEach (inbox_approve)->
			finished_approves.push({
				_id: inbox_approve._id,
				month_finished_time: 0,	#当月已处理总耗时
				month_finished_count: 0,		#当月已完成的处理，本来就是0
				inbox_count: inbox_approve.month_finished_count, 	#未完成数量
				itemsSold: inbox_approve.itemsSold	#所有未审批的开始时间
			})

	else
		finished_approves = []

	# 整理存入数据库中
	if finished_approves.length > 0
		# 未处理文件总耗时
		sumTime = (itemsSold)->
			sum = 0
			if itemsSold.length > 0
				itemsSold.forEach (sold)->
					sum += (now_date - sold?.start_date)
			return sum

		finished_approves.forEach (approve)->
			approve.inbox_time = sumTime(approve.itemsSold)

			if (approve?.month_finished_count + approve?.inbox_count) > 0
				approve.avg_cost_time = (approve?.month_finished_time + approve?.inbox_time)/(approve?.month_finished_count + approve?.inbox_count)
			else
				approve.avg_cost_time = 0

			approve.user = approve?._id?.handler

			approve.year = now_year

			approve.month = now_month

			approve.space = spaceId

			approve.created = now_date

			# 记录级权限
			sharing = {
				'o': [],	#当前用户所有的organization_id
				'p': 'r'
			}

			delete approve.itemsSold

			delete approve._id

			db.instances_cost_time.upsert({
				'user': approve.user,
				'year': approve.year,
				'month': approve.month
				},approve)
			
	return








