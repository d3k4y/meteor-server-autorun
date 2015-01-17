# External code can't access this, and so won't be able to directly construct a Tracker.Computation instance
privateObj = {}
nextId = 1
afterFlushCallbacks = []
queue = new Meteor._SynchronousQueue()

_.extend Tracker,
  _currentComputation: new Meteor.EnvironmentVariable()

  flush: ->
    if not queue.safeToRunTask()
      throw new Error("Can't call Tracker.flush while flushing, or inside Tracker.autorun")

    queue.drain()

  _postRun: ->
    while (queue._taskHandles.length == 0) and (afterFlushCallbacks.length > 0)
      f = afterFlushCallbacks.shift()
      try
        f()
      catch e
        console.log "Exception from Tracker afterFlush function:", e.stack || e.message

  autorun: (f) ->
    c = new Tracker.Computation(f, Tracker.currentComputation, privateObj)

    if Tracker.active
      Tracker.onInvalidate ->
        c.stop()

    c

  nonreactive: (f) ->
    Tracker._currentComputation.withValue null, f

  _makeNonreactive: (f) ->
    if f.$isNonreactive
      return f
    result = (args...) ->
      Tracker.nonreactive =>
        f.apply(@, args)
    result.$isNonreactive = true
    result

  onInvalidate: (f) ->
    if not Tracker.active
      throw new Error("Tracker.onInvalidate requires a currentComputation")

    Tracker.currentComputation.onInvalidate(f)

  afterFlush: (f) ->
    afterFlushCallbacks.push(f)

# Compatibility with the client-side Tracker. On node.js we can use defineProperties to define getters.
Object.defineProperties Tracker,
  currentComputation:
    get: ->
      Tracker._currentComputation.get()

  active:
    get: ->
      !!Tracker._currentComputation.get()

class Tracker.Computation
  constructor: (f, @_parent, p)->
    if p != privateObj
      throw new Error("Tracker.Computation constructor is private; use Tracker.autorun")

    @stopped = false
    @invalidated = false
    @firstRun = true
    @_id = nextId++
    @_onInvalidateCallbacks = []
    @_recomputing = false

    Tracker._currentComputation.withValue @, =>
      @_func = Meteor.bindEnvironment(f, null, @)

    errored = true
    try
      @._compute()
      errored = false
    finally
      @firstRun = false
      if errored
        @stop()

  onInvalidate: (f) ->
    if typeof f != "function"
      throw new Error("onInvalidate requires a function")

    f = Tracker._makeNonreactive(Meteor.bindEnvironment(f, null, @))

    if @invalidated
      f()
    else
      @_onInvalidateCallbacks.push(f)

  invalidate: ->
    if not @invalidated
      if not @_recomputing and not @stopped
        queue.queueTask =>
          @._recompute()
          Tracker._postRun()

      @invalidated = true

      for callback in @_onInvalidateCallbacks
        callback()
      @_onInvalidateCallbacks = []

  stop: ->
    if not @stopped
      @stopped = true
      @invalidate()

  _compute: ->
    @invalidated = false
    @._func(@)

  _recompute: ->
    @_recomputing = true
    while @invalidated and not @stopped
      try
        @._compute()
      catch e
        console.log e
    @_recomputing = false

class Tracker.Dependency
  constructor: ->
    @_dependentsById = {}

  depend: (computation) ->
    unless computation
      return false unless Tracker.currentComputation
      computation = Tracker.currentComputation

    id = computation._id

    if id not of @_dependentsById
      @_dependentsById[id] = computation
      computation.onInvalidate =>
        delete @_dependentsById[id]
      return true

    false

  changed: ->
    for id, computation of @_dependentsById
      computation.invalidate()

  hasDependents: ->
    for id, computation of @_dependentsById
      return true
    false
