fs = require "fs"
spew = require "spew"
_ = require "lodash"
numeral = require "numeral"
S = require "string"
readline = require "readline"
Stream = require "stream"

return spew.error "No input provided" unless filename = process.argv[2]
return spew.error "No small blind specified" unless sb = Number process.argv[3]

# Take off final extension, and append ".out"
outFilename = "#{filename.split(".").slice(0, -1).join "."}.out"
timeStart = Date.now()

spew.info "Got blinds $#{sb}/$#{2*sb}"
spew.info "Writing output to #{outFilename}"

meta = null

###
# Set up file stream (this avoids loading millions of hands into RAM)
###
instream = fs.createReadStream "#{__dirname}/#{filename}"
outstream = new Stream
fileOutStream = fs.createWriteStream "#{__dirname}/#{outFilename}", flags: "w"

time = Date.now()
handSeed = Math.floor((Date.now() / 10000) + ((Math.random() * 100) + 3) * 1000)
parsed = null # We re-use this to speed things up a teensy bit
linesWritten = 0
intermediateCheck = Date.now() # We print progess every 100k records
streamBuffer = [] # Buffer used when we need to wait for a drain event
awaitingDrain = false

rl = readline.createInterface instream, outstream
rl.on "line", (line) ->

  if line.indexOf("name/game/hands/seed") > -1

    ###
    # Parse meta line
    ###

    data = line.split " "
    meta =
      table: data[3].split(".").map((word) -> S(word).capitalize()).join " "
      players: data[2].split(".").length - 3

    spew.info "Got table name #{meta.table}"

    if meta.players == 2 or meta.players == 3
      spew.info "Reading log for #{meta.players} players"
    else
      return spew.error "Unsupported player count: #{meta.players}"

  else if line.indexOf("STATE") > -1
    throw new Error "No meta header at the top of the file ;(" unless meta

    ###
    # Process and stream data
    ###

    # Parse record, increment time and record hand number
    parsed = parseRecord line, meta.players
    parsed.number = handSeed
    handSeed++
    time += (parsed.streets.length * ((Math.random() * 20000) + 15000)) + 5000

    streamBuffer.push generateFTLog parsed, time, meta.table, sb

    # We only write output every 100k lines
    linesWritten++
    if linesWritten % 100000 == 0

      fileOutStream.write streamBuffer.join ""
      streamBuffer = []

      logSpeed intermediateCheck, 100000
      intermediateCheck = Date.now()

fileOutStream.on "drain", ->
  fileOutStream.write streamBuffer.join ""
  streamBuffer = []
  awaitingDrain = false

rl.on "close", ->

  # Write any remaining lines
  if streamBuffer.length > 0
    fileOutStream.write streamBuffer.join ""
    streamBuffer = []

  logSpeed timeStart, linesWritten
  spew.info "Done!"
  process.exit()

###
###
# Methods follow.
###
###

logSpeed = (start, recordCount) ->
  elapsed = Date.now() - start
  handsPerMin = numeral((60000 / elapsed) * recordCount).format ","

  spew.info "Wrote #{recordCount} records in #{elapsed}ms [#{handsPerMin}/min]"

###
# Parse a record string and return a hash with the relevant data.
#
# @param [String] record
# @param [Number] players player count, 2 or 3
# @return [Object] data
###
parseRecord = (record, players) ->
  data = record.split ":"

  unless data[0] == "STATE" and data.length == 6
    return spew.error "Invalid record format: #{record}"

  parsed =
    number: Number data[1]
    action: data[2].split("/").map (action) -> action.split ""
    results: data[4].split("|").map (result) -> Number result
    positions: data[5].split "|"
    streets: []
    cards: []
  
  cardsRaw = data[3].split "|"

  # Get streets
  if cardsRaw[players - 1].indexOf "/"
    temp = data[3].split "/"
    parsed.cards = temp[0].split("|").map (card) -> card.match /.{1,2}/g
    parsed.streets = temp.splice(1).map (street) -> street.match /.{1,2}/g

  parsed

###
# Generate an output string conforming to the FTP log spec, from a parsed data
# object.
#
# @param [Object] parsed
# @param [Number] time time in ms for the hand
# @param [String] table table name
# @param [Number] sb small blind value
# @return [String] output
###
generateFTLog = (parsed, time, table, sb) ->

  bb = sb * 2
  date = new Date time

  dateString = "#{date.getFullYear()}/#{date.getUTCMonth()}/#{date.getUTCDate()}"

  out = """
  Full Tilt Poker Game ##{parsed.number}: Table #{table} - $#{bb}/$#{bb*2} - Limit Hold'em - #{date.toLocaleTimeString()} ET - #{dateString}
  """

  for player, i in parsed.positions
    out += "\nSeat #{i + 1}: #{player} ($1000)"

  # Assuming the player order is SB|BB|BT or BB|SB[BT] for HU
  if parsed.positions.length == 2
    out += "\n#{parsed.positions[1]} posts the small blind of $#{sb}"
    out += "\n#{parsed.positions[0]} posts the big blind of $#{bb}"
  else
    out += "\n#{parsed.positions[0]} posts the small blind of $#{sb}"
    out += "\n#{parsed.positions[1]} posts the big blind of $#{bb}"

  # @TODO: This should be changed to take into account the player order passed
  # in on the first line of the log file, and to use that order for the seating
  if parsed.positions.length == 2
    out += "\nThe button is in seat #2" # HU, order is BB|SB[BT]
  else
    out += "\nThe button is in seat #3" # 3 players, order is SB|BB|BT

  out += "\n*** HOLE CARDS ***"

  for player, i in parsed.positions
    out += "\nDealt to #{player} [#{parsed.cards[i].join " "}]"

  # Pre-flop action, in BT - SB - BB order
  actions = computeActions parsed.positions, parsed.action, sb

  out += actions.output[0]

  if parsed.streets[0]
    out += "\n*** FLOP *** [#{parsed.streets[0].join " "}]"
    out += actions.output[1]

  if parsed.streets[1]
    out += "\n*** TURN *** [#{parsed.streets[0].join " "}] [#{parsed.streets[1][0]}]"
    out += actions.output[2]

  if parsed.streets[2]
    out += "\n*** RIVER *** [#{parsed.streets[0].join " "} #{parsed.streets[1][0]}] [#{parsed.streets[2][0]}]"
    out += actions.output[3]

  out += "\n*** SUMMARY ***"
  out += "\nTotal pot $#{actions.pot} | Rake $0.00"

  # There may not be any streets, if action ends preflop
  if parsed.streets.length > 0
    board = _.reduce parsed.streets, (board, str) -> board.concat str.join " "
    out += "\nBoard: [#{board.join " "}]"

  for player, i in parsed.positions
    switch i
      when 0 then position = "small blind"
      when 1 then position = "big blind"
      when 2 then position = "button"

    hand = parsed.cards[i].join " "
    result = "lost"
    forceSplit = _.filter(parsed.results, (r) -> r == 0).length == parsed.results.length

    # Not net, wtf ;( Wins pot
    if not actions.folded[i] and (forceSplit or parsed.results[i] > 0)

      # Calculate actual # of players to split between
      if forceSplit
        split = actions.playersInShowdown
      else
        split = _.filter(parsed.results, (r) -> r > 0).length

      result = "won ($#{actions.pot / split})"

    out += "\nSeat #{i + 1}: #{player} (#{position}) showed [#{hand}] and #{result}"

  out + "\n\n"

###
# Generate action strings and pot size along with some other info
#
# @param [Array<String>] players player names
# @param [Array<Array<String>>] actions array of actions per street
# @param [Number] sb small blind
# @return [Object] results pot, action strings, + more info
###
computeActions = (players, actions, sb) ->

  bb = sb * 2
  fixedBet = bb
  pot = bb + sb
  output = ["", "", "", ""] # We store output per street

  # We keep an array of fold flags, to keep track of who is still in the hand
  folded = players.map -> false

  for street, i in actions

    ###
    # The order depends on if we are pre-flop or not. So set that up now
    ###
    ordered = []

    # The bet doubles on and after the turn
    if i < 2 then bet = fixedBet else bet = fixedBet * 2

    # We keep track of players by their index in our data arrays
    if i == 0 # Pre-flop

      # HU, players are BB|SB[BT] and order is SB[BT] -BB
      if players.length == 2
        ordered.push i: 1, in: sb unless folded[1]
        ordered.push i: 0, in: bb unless folded[0]

      # 3-way, players are SB|BB|BT and order is BT - SB - BB
      else
        ordered.push i: 2, in: 0  unless folded[2]
        ordered.push i: 0, in: sb unless folded[0]
        ordered.push i: 1, in: bb unless folded[1]

    else # Post-flop

      # HU, players are BB|SB[BT] and order is BB -SB[BT]
      if players.length == 2
        ordered.push i: 0, in: 0 unless folded[0]
        ordered.push i: 1, in: 0 unless folded[1]

      # 3-way, players are SB|BB|BT and order is SB - BB - BT
      else
        ordered.push i: 0, in: 0 unless folded[0]
        ordered.push i: 1, in: 0 unless folded[1]
        ordered.push i: 2, in: 0 unless folded[2]

    ###
    # Now that we have the order, go ahead and run through the actions
    ###
    orderedIndex = -1
    for action, actionNum in street

      # Wrap around action (aka, rrfc with 3 players)
      if orderedIndex == -1
        orderedIndex = actionNum % ordered.length
      else
        orderedIndex = (orderedIndex + 1) % ordered.length

      # Pass over folded players
      while folded[ordered[orderedIndex].i]
        orderedIndex = (orderedIndex + 1) % ordered.length

      player = ordered[orderedIndex]

      switch action
        when "r"
          target = _.max(ordered, (p) -> p.in).in + bet
          pot += target - player.in

          if target == bet
            actionStr = "bets"
          else
            actionStr = "raises to"

          player.in = target
          output[i] += "\n#{players[player.i]} #{actionStr} $#{player.in}"

        when "c"
          target = _.max(ordered, (p) -> p.in).in

          # Check if no raise has been made
          if target == player.in
            output[i] += "\n#{players[player.i]} checks"

          else
            if target == player.in
              spew.warning "Calling $0 [#{players[player.i]} in $#{player.in}]"

            # The FT sample you gave me places a space after the '$' here
            # Blasphemy
            output[i] += "\n#{players[player.i]} calls $ #{target - player.in}"
            pot += target - player.in
            player.in = target

        when "f"
          output[i] += "\n#{players[player.i]} folds"
          folded[player.i] = true

    # Return uncalled bets if only one player is left
    if _.filter(folded, (p) -> !p).length == 1

      # See if player raised past anyone else
      playerIndex = _.findIndex folded, (p) -> !p
      player = _.find ordered, (o) -> o.i == playerIndex

      # Bail if the player doesn't have the highest bet
      if player.in == _.max(ordered, (o) -> o.in).in and player.in > 0

        # Find next highest bet by removing the player and finding the new max
        ordered.splice _.findIndex(ordered, (o) -> o.i == playerIndex), 1
        nextBet = _.max(ordered, (o) -> o.in).in
        pot -= player.in - nextBet

        output[i] += "\nUncalled bet of $#{player.in - nextBet} returned to #{players[playerIndex]}"

  {
    output: output
    pot: pot
    folded: folded
    playersInShowdown: _.filter(folded, (p) -> !p).length
  }
