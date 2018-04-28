logger = new Logger 'Instances_Statistics -> UserCostTime'

# space: 工作区ID
UserCostTime = (space, year, month) ->
	@space = space
	@year = year || null
	@month = month || null
	return

UserCostTime::startStat = () ->
	logger.info 'UserCostTime.startStat()'

	spaceId = @space

	ins_approves = new Array()

	now_date = new Date()

	if @year and @month
		logger.info "指定"+@year+"年"+@month+"月"

		def_date = new Date( @year + "-" + @month )

		def_year = def_date.getFullYear()
		def_month = def_date.getMonth() + 1

		start_date = new Date( def_year + "-" + def_month )
		end_date = new Date( def_year + "-" + def_month )
		end_date.setMonth(end_date.getMonth()+1)

	else
		# 开始日期是当月的一号
		now_year = now_date.getFullYear()
		now_month = now_date.getMonth() + 1
		now_day = now_date.getDate()

		logger.info "不指定年月，默认是" + now_year+"年"+now_month+"月"

		start_date = new Date( now_year + "-" + now_month )

		# 如果统计日期是当月的1号，开始日期 = 统计日期 - 1个月 = 上月1号
		# 每月的1号统计上个月的审批效率
		if now_day == 1
			start_date.setMonth(start_date.getMonth())

		# 结束日期是当月统计的当天
		end_date = now_date

	logger.info "start_date", start_date
	logger.info "end_date", end_date

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
							# 审批未结束的申请单,开始日期 小于 统计结束日期
							{
								$and:[
									{"_approve.is_finished": false},
									{"_approve.start_date": {$lt: end_date}}
								]
							},
							# 审批结束的申请单，且结束日期是在[开始，结束]区间
							{
								$and:[
									{"_approve.finish_date": {$gt: start_date}},
									{"_approve.finish_date": {$lt: end_date}}
								]
							}
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

	if ins_approves?.length > 0

		ins_approves_group = _.groupBy ins_approves, "is_finished"

		# 审批完成的步骤
		finished_approves = ins_approves_group[true] || []

		# 待审批的步骤
		inbox_approves = ins_approves_group[false] || []

		# 遍历已处理的列表
		if finished_approves?.length > 0
			finished_approves.forEach (finished_approve)->

				inbox_approve = _.find(inbox_approves, (item ,index)->
					# 待审批步骤里面的人员和审批完成步骤里面的人员一致
					if item._id?.handler == finished_approve._id?.handler
						inbox_approves.splice(index,1)
						return item
				)

				# 本月待处理数量
				finished_approve.inbox_count = inbox_approve?.month_finished_count||0

				delete finished_approve.is_finished	# 本来就是已完成

				finished_approve.itemsSold = inbox_approve?.itemsSold
		
		# 遍历剩余未处理的列表
		if inbox_approves?.length > 0
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
	if finished_approves?.length > 0

		# 未处理文件总耗时，截止到当月的最后一天
		sumTime = (itemsSold)->
			sum = 0
			if itemsSold?.length > 0
				itemsSold.forEach (sold)->
					minus = (end_date - sold?.start_date) / (1000*60*60)
					sum += minus
			return sum

		# 循环已处理的审批步骤
		finished_approves.forEach (approve)->

			# 当月待处理的总耗时
			inbox_time = sumTime(approve?.itemsSold)

			# 当月待处理的平均耗时
			if approve?.inbox_count > 0
				inbox_avg = inbox_time/approve?.inbox_count
			else
				inbox_avg = 0

			# 当月已处理的总耗时
			month_finished_time = approve.month_finished_time / (1000*60*60)

			# 当月已处理的平均耗时
			if approve?.month_finished_count > 0
				month_finished_avg = month_finished_time/approve?.month_finished_count
			else
				month_finished_avg = 0

			# 总平均耗时
			if (approve?.month_finished_count + approve?.inbox_count) > 0
				avg_time = (month_finished_time + inbox_time)/(approve?.month_finished_count + approve?.inbox_count)
			else
				avg_time = 0

			# double-保留2位
			approve.inbox_time = Math.round(inbox_time*100)/100
			approve.month_finished_time = Math.round(month_finished_time*100)/100
			approve.inbox_avg = Math.round(inbox_avg*100)/100
			approve.month_finished_avg = Math.round(month_finished_avg*100)/100
			approve.avg_time = Math.round(avg_time*100)/100


			userId = approve?._id?.handler

			approve.user = userId

			approve.year = start_date.getFullYear()

			approve.month = start_date.getMonth()+1

			approve.space = spaceId

			approve.created = now_date

			space_user = db.space_users.findOne({'space': spaceId, 'user': userId})

			if space_user
				approve.owner_organization = space_user?.organization
				approve.owner_organizations = space_user?.organizations || []

			delete approve.itemsSold

			delete approve._id

			# 权限有问题，管理员无法查看所有记录，临时这样改

			approve.owner = userId

			db.instances_statistic.upsert({
				'user': approve.user,
				'year': approve.year,
				'month': approve.month
				},approve)
			
	return








