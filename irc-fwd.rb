require 'socket'
require 'openssl'

class IrcFwd
	# admin mask on destination server
	ADMIN_NICK = 'jj'

	attr_accessor :fromhost, :fromport, :tohost, :toport, :fs, :ts, :nick, :queue
	def initialize(fromhost, tohost, *chans)
		@fromhost = fromhost
		@fromport = 6697
		@tohost = tohost
		@toport = 6697
		@nick = ADMIN_NICK + '_proxy'
		@chans = chans
		@queue = []
		@fs = @ts = nil
	end

	def ssl_connect(host, port)
		s = TCPSocket.open(host, port)
		s = OpenSSL::SSL::SSLSocket.new(s, OpenSSL::SSL::SSLContext.new)
		s.sync_close = true
		s.connect
		class << s
			def pending
				@rbuffer.to_s.length + super()
			end
		end
		s
	end

	def verb(s)
		puts "#{Time.now.strftime("%Y%m%d %H%M%S")} #{s}" if $VERBOSE
	end

	def sendl_fs(*a)
		verb "f > #{a.inspect}"
		@fs.write a.join(' ') + "\r\n"
	rescue
		puts "f error #$!"
		sleep 5
		connect_from
	end

	def sendl_ts(*a)
		verb "t > #{a.inspect}"
		@ts.write a.join(' ') + "\r\n"
	rescue
		puts "t error #$!"
		sleep 5
		connect_to
	end

	def sendl_all(*a)
		sendl_fs(*a)
		sendl_ts(*a)
	end

	def wait_read(fds, timeout=0.01)
		if fd = fds.find { |fd_| fd_.pending > 0 }
			return [fd]
		end
		s = IO.select(fds, nil, nil, timeout)
		s[0] if s
	end

	def s_gets(fd, buf)
		while fd.pending > 0 or IO.select([fd], nil, nil, 0)
			buf << fd.read(1)
			if buf[-1, 1] == "\n"
				l = buf.chomp
				buf.replace ''
				return l
			end
		end
	end

	def from_gets
		s_gets(@fs, @from_gets_buf ||= '')
	end

	def to_gets
		s_gets(@ts, @to_gets_buf ||= '')
	end

	def connect_from
		@fs = ssl_connect(@fromhost, @fromport)
		verb "f = connect #{@fromhost} #{@fromport}"
		sendl_fs 'user', @nick, @nick, @nick, @nick
		sendl_fs 'nick', @nick
	end

	def connect_to
		@ts = ssl_connect(@tohost, @toport)
		verb "t = connect #{@tohost} #{@toport}"
		sendl_ts 'user', @nick, @nick, @nick, @nick
		sendl_ts 'nick', @nick
	end

	# parse one irc line: ":from!f@f BLA foo :bar baz"
	def parse_irc_line(l)
		l = l.chomp
		parts = []

		if l[0, 1] == ':'
			from, l = l.split(/\s+/, 2)
			parts << from[1..-1]
		else
			parts << nil
		end

		while l.to_s.length > 0
			if l[0, 1] == ':'
				parts << l[1..-1]
				break
			end
			ps, l = l.split(/\s+/, 2)
			parts << ps
		end

		parts
	end

	def handle_from(parts)
		case parts[1].upcase
		when '376'
			@chans.each { |c| sendl_fs 'join', c }
		when '433'	# nick already in use
			sendl_fs 'nick', "#{@nick}_#{rand(1000)}"
		when 'PRIVMSG'
			if @chans.include?(parts[2])
				@queue << [parts[2], "<#{parts[0].to_s.sub(/!.*/, '')}> #{parts[3]}"]
			end
		when 'PING'
			sendl_fs 'PONG', parts[2]
		end
	end

	def handle_to(parts)
		case parts[1].upcase
		when '376'
			@chans.each { |c| sendl_ts 'join', c }
		when '433'	# nick already in use
			sendl_ts 'nick', "#{@nick}_#{rand(1000)}"
		when 'PRIVMSG'
			if false and parts.last =~ /^!say (.*)$/
				# reverse proxy: send msg to 'from' server (same chan)
				sendl_fs 'privmsg', parts[2], "<#{parts[0].to_s.sub(/!.*/, '')}> #{parts[3]}"
			end

			if parts[0] =~ /^#{ADMIN_NICK}!/
				case parts.last
				when /^!reload$/
					load __FILE__
				when /^!reconnect$/
					reconnect
				when /^!clear$/
					@queue.clear
				when /^!join (\S+)$/
					@chans << $1
					sendl_all 'join', $1
				when /^!part (\S+)$/
					@chans.delete $1
					sendl_all 'part', $1
				when /^!quit$/
					sendl_all 'quit', ':quat'
					exit
				when /^!nick (\S+)$/
					@nick = $1
					sendl_all 'nick', @nick
				when /^!info$/
					sendl_ts 'privmsg', ADMIN_NICK, ":chans #{@chans.inspect} queue #{@queue.length}"
				when /^!rawf (.*)$/
					sendl_fs $1
				when /^!rawt (.*)$/
					sendl_ts $1
				#when /^!bench (\d+)$/
				#	$1.to_i.times { |i| @queue << [ADMIN_NICK, "<bench> #{i}"] }
				end
			end
		when 'PING'
			sendl_ts 'PONG', parts[2]
		end
	end

	def main_loop
		loop { main_iter }
	end

	def main_iter
		fds = wait_read([@ts, @fs].compact, main_timeout)

		if fds and fds.include?(@ts) and l = to_gets
			parts = parse_irc_line(l)
			verb "t < #{parts.inspect}"
			handle_to(parts)
		end
		if fds and fds.include?(@fs) and l = from_gets
			parts = parse_irc_line(l)
			verb "f < #{parts.inspect}"
			handle_from(parts)
		end
		
		main_send
	rescue
		puts "Exception: #{$!.class} #$!", $!.backtrace
		sleep 1
	end

	def main_timeout
		if @queue.empty?
			2
		else
			# 0.7 gets throttled on libera
			tn = Time.now
			@last_queue_send ||= tn - 1
			nt = @last_queue_send + 0.8
			if nt - tn > 0.01 and nt - tn < 0.8
				nt - tn
			else
				0.8
			end
		end
	end

	def main_send
		if @queue.first
			tn = Time.now
			@last_queue_send ||= tn - 1
			if tn - @last_queue_send >= 0.8
				@last_queue_send = tn
				dst, msg = @queue.shift
				sendl_ts 'privmsg', dst, ":#{msg}"
			end
		else
			@to_last_ping ||= 0
			if @to_last_ping < Time.now.to_i - 15*60
				@to_last_ping = Time.now.to_i
				sendl_ts 'PING', ':timeout'
			end
			@from_last_ping ||= 0
			if @from_last_ping < Time.now.to_i - 15*60
				@from_last_ping = Time.now.to_i
				sendl_fs 'PING', ':timeout'
			end
		end
	end

	def reconnect
		sendl_fs 'quit', ':quat' if @fs
		connect_from
		sendl_ts 'quit', ':quat' if @ts
		connect_to
	end
end

if $0 == __FILE__
	$ifw ||= nil
	if !$ifw
		abort "usage: fwd <fromsrv> <tosrv> [chans]" if ARGV.length < 2
		$ifw = IrcFwd.new(*ARGV)
		$ifw.reconnect
		$ifw.main_loop
	end
end
