############################################################################
#     Copyright (C) 2014 by Vaughn Iverson
#     jobCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

if Meteor.isServer


  ################################################################
  ## jobCollection server DDP methods

  serverMethods =

    # Job manager methods

    getJob: (id) ->
      console.log "Get: ", id
      if id
        d = @findOne({_id: id}, { fields: { log: 0 } })
        if d
          console.log "get method Got a job", d
          return d
        else
          console.warn "Get failed job"
      else
        console.warn "Bad id in get", id
      return null

    jobRemove: (id) ->
      if id
        num = @remove({ _id: id, status: {$in: ["cancelled", "failed", "completed"] }})
        if num is 1
          console.log "jobRemove succeeded"
          return true
        else
          console.warn "jobRemove failed"
      else
        console.warn "jobRemoved something's wrong with done: #{id}"
      return false

    jobCancel: (id) ->
      if id
        time = new Date()
        num = @update(
          { _id: id, status: {$in: ["ready", "waiting", "running"] }}
          { $set: { status: "cancelled", runId: null, progress: { completed: 0, total: 1, percent: 0 }, updated: time }})
        if num is 1
          console.log "jobCancel succeeded"
          return true
        else
          console.warn "jobCancel failed"
      else
        console.warn "jobCancel: something's wrong with done: #{id}", runId, err
      return false

    jobRestart: (id, attempts) ->
      if id
        time = new Date()
        num = @update(
          { _id: id, status: {$in: ["cancelled", "failed"] }}
          { $set: { status: "waiting", progress: { completed: 0, total: 1, percent: 0 }, updated: time }, $inc: { attempts: attempts }})
        if num is 1
          console.log "jobRestart succeeded"
          return true
        else
          console.warn "jobRestart failed"
      else
        console.warn "jobRestart: something's wrong with done: #{id}", runId, err
      return false

    # Job creator methods

    jobSubmit: (doc) ->
      if doc._id
        num = @update(
          { _id: doc._id, runId: null }
          { $set: { attempts: doc.attempts, attemptsWait: doc.attemptsWait, depends: doc.depends, priority: doc.priority, after: doc.after }})
      else
        return @insert doc

    # Worker methods

    getWork: (type) ->
      # Support string types or arrays of string types
      if typeof type is 'string'
        type = [ type ]

      console.log "Process: ", type
      time = new Date()
      d = @findOne(
        { type: { $in: type }, status: 'ready', runId: null, after: { $lte: time }, attempts: { $gt: 0 }}
        { sort: { priority: -1, after: 1 } })

      if d
        console.log "Found a job to process!", d
        run_id = new Meteor.Collection.ObjectID()
        num = @update(
          { _id: d._id, status: 'ready', runId: null, after: { $lte: time }, attempts: { $gt: 0 }}
          { $set: { status: 'running', runId: run_id, updated: time }, $inc: { attempts: -1, attempted: 1 } })
        if num is 1
          console.log "Update was successful", d._id
          dd = @findOne { _id: d._id }
          if dd
            console.log "findOne was successful"
            return dd
          else
            console.warn "findOne after update failed"
        else
          console.warn "Missing running job"
      else
        console.log "Didn't find a job to process"
      return null

    jobProgress: (id, runId, progress) ->
      if id and runId and progress
        time = new Date()
        console.log "Updating progress", id, runId, progress
        num = @update(
          { _id: id, runId: runId, status: "running" }
          { $set: { progress: progress, updated: time }})
        if num is 1
          console.log "jobProgress succeeded", progress
          return true
        else
          console.warn "jobProgress failed"
      else
        console.warn "jobProgress: something's wrong with progress: #{id}", progress
      return false

    jobLog: (id, runId, message) ->
      if id and message
        time = new Date()
        console.log "Logging a message", id, runId, message
        num = @update(
          { _id: id }
          { $push: { log: { time: time, runId: runId, message: message }}, $set: { updated: time }})
        if num is 1
          console.log "jobLog succeeded", message
          return true
        else
          console.warn "jobLog failed"
      else
        console.warn "jobLog: something's wrong with progress: #{id}", message
      return false

    jobDone: (id, runId, err, wait) ->
      if id and runId
        time = new Date()
        unless err?
          num = @update(
            { _id: id, runId: runId, status: "running" }
            { $set: { status: "completed", progress: { completed: 1, total: 1, percent: 100 }, updated: time }})
          if num
            # Resolve depends
            n = @update({status: "waiting", depends: { $all: [ id ]}}, { $pull: { depends: id }, $push: {log: { time: time, runId: null, message: "Dependency resolved for #{id} by #{runId}"}}})
            console.log "Job #{id} Resolved #{n} depends"
        else
          num = @update(
            { _id: id, runId: runId, status: "running" }
            { $set: { status: "failed", runId: null, after: new Date(time.valueOf() + wait), progress: { completed: 0, total: 1, percent: 0 }, updated: time }, $push: {log: { time: time, runId: runId, message: "Job Failed with Error #{err}"}}})
        if num is 1
          console.log "jobDone succeeded"
          return true
        else
          console.warn "jobDone failed"
      else
        console.warn "jobDone: something's wrong with done: #{id}", runId, err
      return false

  ################################################################
  ## jobCollection server class

  class jobCollection extends Meteor.Collection

    constructor: (@root = 'queue', options = {}) ->
      unless @ instanceof jobCollection
        return new jobCollection(@root, options)

      # Call super's constructor
      super @root + '.jobs', { idGeneration: 'MONGO' }

      # No client mutators allowed
      @deny
        update: () => true
        insert: () => true
        remove: () => true

      @promote()
      @expire()

      @logStream = options.logStream ? null

      @permissions = options.permissions ? { allow: true, deny: false }

      Meteor.methods(@_generateMethods serverMethods)

    _method_wrapper: (method, func) ->

      toLog = (userId, message) =>
        # console.warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        @logStream?.write "#{new Date()}, #{userId}, #{method}, #{message}\n"

      myTypeof = (val) ->
        type = typeof val
        type = 'array' if type is 'object' and type instanceof Array
        return type

      permitted = (userId, params) =>

        performTest = (test, def) =>
          switch myTypeof test
            when 'boolean' then test
            when 'array' then userId in test
            when 'function' then test userId, method
            when 'object'
              methodType = myTypeof test?[method]
              switch methodType
                when 'boolean' then test[method]
                when 'array' then userId in test[method]
                when 'function' then test?[method]? userId, params
                else def
            else def

        return performTest(@permissions.allow, true) and not performTest(@permissions.deny, false)

      # Return the wrapper function that the Meteor method will actually invoke
      return (params...) ->
        user = this.userId ? "[UNAUTHENTICATED]"
        unless this.connection
          user = "[SERVER]"
        # console.log "!!!!!!", JSON.stringify params
        toLog user, "params: " + JSON.stringify(params)
        unless this.connection and not permitted(this.userId, params)
          retval = func(params...)
          toLog user, "returned: " + JSON.stringify(retval)
          return retval
        else
          toLog this.userId, "UNAUTHORIZED."
          throw new Meteor.Error 403, "Method not authorized", "Authenticated user is not permitted to invoke this method."

    _generateMethods: (methods) ->
      methodsOut = {}
      methodsOut["#{methodName}_#{root}"] = @_method_wrapper(methodName, methodFunc.bind(@)) for methodName, methodFunc of methods
      return methodsOut

    createJob: (params...) -> new Job @root, params...

    getJob: (params...) -> Job.getJob @root, params...

    getWork: (params...) -> Job.getWork @root, params...

    promote: (milliseconds = 15*1000) ->
      if typeof milliseconds is 'number' and milliseconds > 1000
        if @interval
          Meteor.clearInterval @interval
        @interval = Meteor.setInterval @_poll.bind(@), milliseconds
      else
        console.warn "jobCollection.promote: invalid timeout or limit: #{@root}, #{milliseconds}, #{limit}"

    expire: (milliseconds = 2*60*1000) ->
      if typeof milliseconds is 'number' and milliseconds > 1000
        @expireAfter = milliseconds

    _poll: () ->
      time = new Date()
      num = @update(
        { status: "waiting", after: { $lte: time }, depends: { $size: 0 }}
        { $set: { status: "ready", updated: time }, $push: { log: { time: time, runId: null, message: "Promoted to ready" }}}
        { multi: true })
      console.log "Ready fired: #{num} jobs promoted"

      exptime = new Date( time.valueOf() - @expireAfter )
      console.log "checking for expiration times before", exptime

      num = @update(
        { status: "running", updated: { $lte: exptime }, attempts: { $gt: 0 }}
        { $set: { status: "ready", runId: null, updated: time, progress: { completed: 0, total: 1, percent: 0 } }, $push: { log: { time: time, runId: null, message: "Expired to retry" }}}
        { multi: true })
      console.log "Expired #{num} dead jobs, waiting to run"

      num = @update(
        { status: "running", updated: { $lte: exptime }, attempts: 0}
        { $set: { status: "failed", runId: null, updated: time, progress: { completed: 0, total: 1, percent: 0 } }, $push: { log: { time: time, runId: null, message: "Expired to failure" }}}
        { multi: true })
      console.log "Expired #{num} dead jobs, failed"