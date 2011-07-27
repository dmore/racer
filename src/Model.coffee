transaction = require './transaction'
pathParser = require './pathParser'
MemorySync = require './adapters/MemorySync'
TxnApplier = require './TxnApplier'

Model = module.exports = (@_clientId = '', AdapterClass = MemorySync) ->
  model = self = this
  self._initAdapter self._adapter = new AdapterClass
  
  self._storeSubs = []  # Paths in the store that this model is subscribed to
  self._eventSubs = {}  # Record of Model.on event subscriptions
  
  self._txnCount = 0
  self._txns = {}
  self._txnQueue = []
  
  txnApplier = new TxnApplier
    applyTxn: (txn) -> self._applyTxn txn
    onTimeout: -> self._reqNewTxns()
  
  self._onTxn = (txn, num) ->
    # Copy the callback onto this transaction if it matches one in the queue
    if queuedTxn = self._txns[transaction.id txn]
      txn.callback = queuedTxn.callback
    txnApplier.add txn, num
  
  self._onTxnNum = (num) ->
    # Reset the number used to keep track of pending transactions
    txnApplier.setIndex (+num || 0) + 1
    txnApplier.clearPending()
  
  self.force = Object.create self, _force: value: true
  
  return

Model:: =

  ## Socket.io communication ##
  
  _commit: -> false
  _reqNewTxns: ->
  _setSocket: (socket) ->
    self = this
    self.socket = socket
    
    socket.on 'txn', self._onTxn
    socket.on 'txnNum', self._onTxnNum
    socket.on 'txnOk', (base, txnId, num) ->
      if txn = self._txns[txnId]
        txn[0] = base
        self._onTxn txn, num
    socket.on 'txnErr', (err, txnId) ->
      txn = self._txns[txnId]
      if txn && (callback = txn.callback) && err != 'duplicate'
        args = transaction.args txn
        args.unshift err
        callback args...
      self._removeTxn txnId
    
    self._commit = commit = (txn) ->
      txn.timeout = +new Date + SEND_TIMEOUT
      socket.emit 'txn', txn
    
    # Request any transactions that may have been missed
    self._reqNewTxns = -> socket.emit 'txnsSince', self._adapter.ver + 1
    
    resendAll = ->
      txns = self._txns
      commit txns[id] for id in self._txnQueue
    resendExpired = ->
      now = +new Date
      txns = self._txns
      for id in self._txnQueue
        txn = txns[id]
        return if txn.timeout > now
        commit txn
    
    # Request missed transactions and send queued transactions on connect
    resendInterval = null
    socket.on 'connect', ->
      socket.emit 'sub', self._clientId, self._storeSubs
      self._reqNewTxns()
      resendAll()
      unless resendInterval
        resendInterval = setInterval resendExpired, RESEND_INTERVAL
    socket.on 'disconnect', ->
      clearInterval resendInterval
      resendInterval = null


  ## Model events ##
  
  on: (method, pattern, callback) ->
    re = pathParser.regExp pattern
    sub = [re, callback]
    subs = @_eventSubs
    if subs[method] is undefined
      subs[method] = [sub]
    else
      subs[method].push sub
  
  _emit: (method, [path, args...]) ->
    return unless subs = @_eventSubs[method]
    emitPathEvents = (path) ->
      for [re, callback] in subs
        if re.test path
          callback.apply null, re.exec(path).slice(1).concat(args)
    emitPathEvents path
    # Emit events on any references that point to the path
    if refs = @get '$refs'
      self = this
      # Passes back a set of references when we find references to path.
      # Also passes back a set of references and a path remainder
      # every time we find references to any of path's ancestor paths
      # such that `ancestor_path + path_remainder == path`
      eachRefSetPointingTo = (path, fn) ->
        i = 0
        refPos = refs
        props = path.split '.'
        while prop = props[i++]
          return unless refPos = refPos[prop]
          fn refSet, props.slice(i).join('.') if refSet = refPos.$
      emitRefs = (targetPath) ->
        eachRefSetPointingTo targetPath, (refSet, targetPathRemainder) ->
          # refSet has signature: { "#{pointingPath}$#{ref}": [pointingPath, ref], ... }
          self._eachValidRef refSet, self.get(), (pointingPath) ->
            derefPath = pointingPath
            derefPath += '.' + targetPathRemainder if targetPathRemainder
            emitPathEvents derefPath
            emitRefs derefPath

      emitRefs path
  
  _fastLookup: (path, obj) ->
    for prop in path.split '.'
      return unless obj = obj[prop]
    return obj
  _eachValidRef: (refs, obj = @_adapter._data, callback) ->
    fastLookup = @_fastLookup
    for path$ref$key, [path, ref, key] of refs
      # Check to see if the reference is still the same
      o = fastLookup path, obj
      if o && o.$r == ref && o.$k == key
        callback path, ref, key
      else
        delete refs[path$ref$key]

  # If a key is present, merges
  #     { "#{path}$#{ref}#{key}": [path, ref, key] }
  # into
  #     "$keys":
  #       "#{key}":
  #         $:
  #
  # and merges
  #     { "#{path}$#{ref}": [path, ref] }
  # into
  #     "$refs":
  #       "#{ref}.#{keyObj}": 
  #         $:
  #
  # If key is not present, merges
  #     "#{path}$#{ref}": [path, ref]
  # into
  #     "$refs":
  #       "#{ref}": 
  #         $:
  #
  # $refs is a kind of index that allows us to lookup
  # which references pointed to the path, `ref`, or to
  # a path that `ref` is a descendant of.
  #
  # @param {String} path that is de-referenced to a true path represented by
  #                 lookup(ref + '.' + lookup(key))
  # @param {String} ref is what would be the `value` of $r: `value`.
  #                 It's what we are pointing to
  # @param {String} key is a path that points to a pathB or array of paths
  #                 as another lookup chain on the dereferenced `ref`
  # @param {Object} options
  _setRefs: (path, ref, key, options) ->
    adapter = @_adapter
    if key
      value = [path, ref, key]
      i = value.join '$'
      adapter._lookup("$keys.#{key}.$", true, options).obj[i] = value
      keyObj = adapter._lookup(key, false, options).obj
      # keyObj is only valid if it can be a valid path segment
      return if keyObj is undefined
      ref = ref + '.' + keyObj
    else
      value = [path, ref]
      i = value.join '$'
    adapter._lookup("$refs.#{ref}.$", true, options).obj[i] = value
  
  _initAdapter: (adapter) ->
    self = this
    adapter.__set = adapter.set
    adapter.set = (path, value, ver, options = {}) ->
      out = adapter.__set path, value, ver, options
      # Save a record of any references being set
      self._setRefs path, ref, value.$k, options if value && ref = value.$r
      # Check to see if setting to a reference's key. If so, update references
      if refs = adapter._lookup("$keys.#{path}.$", false, options).obj
        self._eachValidRef refs, options.obj, (path, ref, key) ->
          self._setRefs path, ref, key, options
      return out
  
  # Creates a reference object for use in model data methods
  ref: (ref, key, arrOnly) ->
    if arrOnly
      return $r: ref, $k: key, $o: arrOnly
    if key? then $r: ref, $k: key else $r: ref
  
  
  ## Transaction handling ##
  
  _nextTxnId: -> @_clientId + '.' + @_txnCount++
  
  _addTxn: (method, args..., callback) ->
    # Create a new transaction and add it to a local queue
    id = @_nextTxnId()
    ver = if @_force then null else @_adapter.ver
    @_txns[id] = txn = [ver, id, method, args...]
    txn.callback = callback
    @_txnQueue.push id
    # Update the transaction's path with a dereferenced path
    path = txn[3] = args[0] = @_specModel()[1]
    # Apply a private transaction immediately and don't send it to the store
    return @_applyTxn txn if pathParser.isPrivate path
    # Emit an event on creation of the transaction
    @_emit method, args
    # Send it over Socket.IO or to the store on the server
    @_commit txn
  
  _removeTxn: (txnId) ->
    delete @_txns[txnId]
    txnQueue = @_txnQueue
    if ~(i = txnQueue.indexOf txnId) then txnQueue.splice i, 1
  
  _applyTxn: (txn) ->
    method = transaction.method txn
    args = transaction.args txn
    args.push transaction.base txn
    @_adapter[method] args...
    @_removeTxn transaction.id txn
    @_emit method, args
    callback null, transaction.args(txn)... if callback = txn.callback
  
  # TODO Will re-calculation of speculative model every time result
  #      in assignemnts to vars becoming stale?
  _specModel: ->
    adapter = @_adapter
    if len = @_txnQueue.length
      # Then generate a speculative model
      obj = Object.create adapter.get()
      i = 0
      while i < len
        # Apply each pending operation to the speculative model
        txn = @_txns[@_txnQueue[i++]]
        args = transaction.args txn
        args.push adapter.ver, obj: obj, proto: true
        path = adapter[transaction.method txn] args...
    return [obj, path]
  
  
  ## Data accessor and mutator methods ##
  
  get: (path) -> @_adapter.get path, @_specModel()[0]
  
  set: (path, value, callback) ->
    @_addTxn 'set', path, value, callback
    return value
  
  del: (path, callback) ->
    @_addTxn 'del', path, callback

  ## Array methods ##
  
  push: (path, values..., callback) ->
    if 'function' != typeof callback && callback isnt undefined
      values.push callback
      callback = null
    @_addTxn 'push', path, values..., callback

  pop: (path, callback) ->
    @_addTxn 'pop', path, callback

  unshift: (path, values..., callback) ->
    if 'function' != typeof callback && callback isnt undefined
      values.push callback
      callback = null
    @_addTxn 'unshift', path, values..., callback

  shift: (path, callback) ->
    @_addTxn 'shift', path, callback

  insertAfter: (path, afterIndex, value, callback) ->
    @_addTxn 'insertAfter', path, afterIndex, value, callback

  insertBefore: (path, beforeIndex, value, callback) ->
    @_addTxn 'insertBefore', path, beforeIndex, value, callback

  remove: (path, startIndex, howMany, callback) ->
    @_addTxn 'remove', path, startIndex, howMany, callback

  splice: (path, startIndex, removeCount, newMembers..., callback) ->
    if 'function' != typeof callback && callback isnt undefined
      newMembers.push callback
      callback = null
    @_addTxn 'splice', path, startIndex, removeCount, newMembers..., callback

# Timeout in milliseconds after which sent transactions will be resent
Model._SEND_TIMEOUT = SEND_TIMEOUT = 10000
# Interval in milliseconds to check timeouts for queued transactions
Model._RESEND_INTERVAL = RESEND_INTERVAL = 2000
