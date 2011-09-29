Model = require 'Model'
should = require 'should'
util = require './util'
transaction = require 'transaction'
wrapTest = util.wrapTest

{mockSocketModels} = require './util/model'

module.exports =
  'Model::atomic should log gets @single': wrapTest (done) ->
    model = new Model
    model.atomic (model) ->
      model.get 'color'
      model.oplog().length.should.equal 1
      op = model.oplog()[0]
      transaction.method(op).should.equal 'get'
      done()

  '''AtomicModel::oplog should only contain the ops that
  *it* has done @single''': wrapTest (done) ->
    model = new Model
    model.set 'direction', 'west'
    model.atomic (model) ->
      model.get 'color'
      model.oplog().length.should.equal 1
      op = model.oplog()[0]
      transaction.method(op).should.equal 'get'
      transaction.args(op).should.eql ['color']
      model._txnQueue.length.should.equal 2
      done()

  '''AtomicModel should keep around the transactions of
  its parent's model @single''': wrapTest (done) ->
    model = new Model
    model.set 'direction', 'west'
    model.atomic (model) ->
      model.get 'color'
      parentTxn = model._txns[model._txnQueue[0]]
      transaction.method(parentTxn).should.equal 'set'
      transaction.args(parentTxn).should.eql ['direction', 'west']
      done()

  '''AtomicModel sets should be reflected in the atomic
  model but not the parent model @single''': wrapTest (done) ->
    model = new Model
    model.set 'direction', 'west'
    model.atomic (atomicModel) ->
      atomicModel.set 'direction', 'north'
      model.get().should.specEql direction: 'west'
      atomicModel.get().should.specEql direction: 'north'
      done()

  '''AtomicModel sets should be reflected in the parent
  speculative model after an implicit commit -- i.e., if no
  commit param was passed to model.atomic @single''': wrapTest (done) ->
    model = new Model
    model.set 'direction', 'west'
    model.atomic (atomicModel) ->
      atomicModel.set 'direction', 'north'
    model.get().should.specEql direction: 'north'
    done()

  '''if passed an explicit commit callback, AtomicModel
  should not reflect any of its ops in the parent speculative
  model until the commit callback is invoked inside the
  atomic block @single''': wrapTest (done) ->
    model = new Model
    model.set 'direction', 'west'
    model.atomic (atomicModel, commit) ->
      atomicModel.set 'direction', 'north'
      setTimeout ->
        commit()
        done()
      , 200
    model.get().should.specEql direction: 'west'


  '''Model::atomic(lambda, callback) should invoke its
  callback once it receives a successful response for
  the txn from the upstream repo @single''': wrapTest (done) ->
    # stub out appropriate methods/callbacks in model
    # to fake a successful response without going through
    # additional Store + Socket.IO + STM + Redis stack
    [sockets, model] = mockSocketModels 'model', txnOk: true
    model.atomic (atomicModel) ->
      atomicModel.set 'direction', 'north'
    , (err, num) ->
      should.equal null, err
      sockets._disconnect()
      done()

  '''Model::atomic(lambda, callback) should callback
  with an error if the commit failed at some point
  in an upstream repo @single''': wrapTest (done) ->
    [sockets, model] = mockSocketModels 'model', txnErr: 'conflict'
    model.atomic (atomicModel) ->
      atomicModel.set 'direction', 'north'
    , (err) ->
      err.should.equal 'conflict'
      sockets._disconnect()
      done()

  '''AtomicModel commits should not callback if it has not
  yet received the status of that commit @single''': wrapTest (done) ->
    [sockets, model] = mockSocketModels 'model', txnOk: false
    counter = 1
    model.atomic (atomicModel) ->
      atomicModel.set 'direction', 'north'
    , (err) ->
      counter++
    setTimeout ->
      counter.should.equal 1
      sockets._disconnect()
      done()
    , 200

  '''AtomicModel should commit *all* its ops to the parent
  model's permanent, non-speculative data upon a successful
  transaction response from the parent repo @single''': wrapTest (done) ->
    [sockets, model] = mockSocketModels 'model', txnOk: true
    model.atomic (atomicModel) ->
      atomicModel.set 'color', 'green'
      atomicModel.set 'volume', 'high'
    , (err) ->
      should.equal null, err
      model._adapter._data.should.eql
        color: 'green'
        volume: 'high'
      sockets._disconnect()
      done()

  '''a model should clean up its atomic model upon a
  successful commit of that atomic model's transaction @single''': wrapTest (done) ->
    [sockets, model] = mockSocketModels 'model', txnOk: true
    atomicModelId = null
    model.atomic (atomicModel) ->
      atomicModelId = atomicModel.id
      atomicModel.set 'direction', 'north'
    , (err) ->
      should.equal null, err
      should.equal undefined, model._atomicModels[atomicModelId]
      sockets._disconnect()
      done()

  '''a model should not clean up its atomic model before the
  result of a commit (success or err) is known @single''': wrapTest (done) ->
    [sockets, model] = mockSocketModels 'model', txnOk: true
    atomicModelId = null
    model.atomic (atomicModel, commit) ->
      atomicModelId = atomicModel.id
      atomicModel.set 'direction', 'north'
      setTimeout commit, 200
    , (err) ->
      should.equal null, err
      should.equal undefined, model._atomicModels[atomicModelId]
      sockets._disconnect()
      done()
    model._atomicModels[atomicModelId].should.not.be.undefined

  '''an atomic model should be able to retry itself when
  handling a commit err via the model.atomic callback''': -> # TODO

  # TODO Pass the following tests

  # TODO Tests involving refs and array refs

  # TODO Tests for event emission proxying to parent models

  # TODO Tests for nested, composable transactions

  # TODO How to handle private paths?

  'AtomicModel commits should get passed to Store': -> # TODO

  'AtomicModel commits should get passed to STM': -> # TODO

  '''a parent model should pass any speculative ops
  to its child atomic models''': -> # TODO

  '''a parent model should pass any accepted ops to
  its child atomic models''': -> #TODO

  '''a parent model should pass any aborted ops to
  its child atomic models''': -> #TODO

#  'a failed atomic transaction should not have any of its ops persisted': wrapTest (done)->
#    [socket, modelA, modelB] = mockSocketModels 'modelA', 'modelB'
#    modelA.atomic (model) ->
#      model.set 'color', 'green'
#      model.set 'volume', 'high'
#    , (err) ->
#      err.should.equal 'conflict'
#      done()
#  , 1