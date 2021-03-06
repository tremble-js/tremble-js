# load npbody.head_commit.id
winston = require 'winston'
Q = require 'q'
amqp = require 'amqplib'
mkdirp = require 'mkdirp'
_ = require 'lodash'
phantom = require 'phantom'
uuid = require 'uuid'
config = require './tremble'
dropbox = require 'dropbox'
mongoose = require('mongoose')

console.log config

# load local modules
models = require("./utils/schema").models
app = require("./tasks/phantom")
compare = require("./tasks/compare")

# configure app
winston.level = process.env.WINSTON_LEVEL
port = process.env.PORT or 3002
rabbitMQ = process.env.RABBITMQ_BIGWIG_URL
q = process.env.RABBITMQ_QUEUE
Q.longStackSupport = true
mongoose.connect process.env.MONGO_DB

# error handler
setupError = (err) ->
  winston.error err
  process.exit 1

# process request
doWork = (msg) ->
  winston.log 'info', 'doWork'

  mkSSDir = () ->
    mkdirp 'screenshots', (err) ->
      if err == null
        winston.log 'verbose', 'mkdir screenshots'

  try
    ssDir = fs.lstatSync 'screenshots'

    if ssDir.isDirectory() != true
      mkSSDir()
  catch e
    mkSSDir()

  body = JSON.parse msg.content.toString()

  loadUserData app, body.sender.login
    .then (app) ->
      commit =  body.head_commit.id

      logEntry = new models.log
        commit: commit
        repo: body.repository.full_name
        request: msg.content

      app.user.repo = body.repository.full_name

      if typeof body.organization != 'undefined'
        username = body.organization.login
        type = 'org'
      else
        username = body.repository.owner.login
        type = 'user'

      phantom.create (ph) ->
        winston.log 'info', 'Starting phantom'

        Q.all(_.map(config.pages, (page) ->
          Q.all(_.map(config.resolutions, (res) ->
            config =
              host: "http://localhost"
              route_name: page.title
              route: page.path
              delay: config.delay
              port: port
              ph: ph
              commit: commit
              res: res
              repo: body.repository.full_name

            app.process config
            .then app.open
            .then app.setRes
            .then app.capture
            .then app.updateUser
            .then app.saveDropbox
            .catch (err) ->
              winston.error err
              app.rabbitCH.nack msg, false, false
          ))
        )).then (res) ->
          deferred = Q.defer()

          logEntry.user = app.user
          app.user.images.sort (a, b) ->
            1 if a.createdAt < b.createdAt
            -1 if b.createdAt < a.createdAt
            0

          keys = []
          _.each app.user.images, (img) ->
            keys.push img.commit if keys.indexOf(img.commit) <= -1

          keys = keys.slice 1, 3 if keys.length >= 3

          app.user.images = _.filter app.user.images, (img) ->
            keys.indexOf(img.commit) > -1

          app.user.save (err) ->
            deferred.reject err if err
            winston.log 'info', 'saved image in mongo'
            deferred.resolve app.user

          deferred.promise
        .then compare.saveToDisk
        .then compare.compare
        .then (user) ->
          deferred = Q.defer()

          logEntry.results= app.user.newResults
          logEntry.status = "success"

          logEntry.save (err) ->
            deferred.reject err if err

          user.save (err) ->
            deferred.reject err if err
            winston.log 'info', 'saved compare results in mongo'
            deferred.resolve app.user

          winston.log 'info', 'Shutting down phantom'
          app.rabbitCH.ack msg
          ph.exit()

          deferred.promise
        .catch (err) ->
          logEntry.status = "error"
          logEntry.message = err

          logEntry.save (err) ->
            deferred.reject err if err

# setup rabbit channel
setupWorker = (app) ->
  winston.log 'info', 'setting up worker'
  winston.log 'info', 'asserting channel %s', q
  ok = app.rabbitCH.assertQueue q,
    durable: true

  ok = ok.then ->
    app.rabbitCH.prefetch 1

  ok = ok.then ->
    app.rabbitCH.consume q, doWork, noAck: false

  ok

# load user
loadUserData = (app, login) ->
  # todo: @obihann change this find based on
  # github id obtained from pull request
  winston.log 'info', 'loading user from database'
  models.user.findOne({ username: login}).exec()
  .then (user) ->
    app.user = user
    app
  .then (app) ->
    client = new dropbox.Client
      key: process.env.DROPBOX_KEY
      secret: process.env.DROPBOX_SECRET
      sandbox: true
      token: app.user.dropbox.accessToken

    client.authDriver new dropbox.AuthDriver.NodeServer(8191)

    app.dropbox = client
    app
  .then null, (err) ->
    setupError(err) if err
  .end()

# open connection to rabbitMQ
loadRabbit = (app) ->
  winston.log 'info', 'connecting to rabbitMQ %s', rabbitMQ
  amqp.connect rabbitMQ
  .then (conn) ->
    winston.log 'info', 'creating channel'
    app.rabbitConn = conn

    conn.createChannel()
  .then (ch) ->
    app.rabbitCH = ch

    app
  .catch (err) ->
    setupError err

# initialize worker
loadRabbit app
  .then(setupWorker)

module.exports = app
