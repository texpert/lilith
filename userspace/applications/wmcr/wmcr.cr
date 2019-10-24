require "./wm/*"

lib LibC
  struct Winsize
    ws_row : UInt16
    ws_col : UInt16
    ws_xpixel : UInt16
    ws_ypixel : UInt16
  end
  TIOCGWINSZ = 2

  @[Packed]
  struct MousePacket
    x : UInt32
    y : UInt32
    attr_byte : UInt32
  end

end

FRAME_WAIT = 10000
CURSOR_FILE = "/hd0/share/cursors/cursor.png"

module Wm
  extend self

  abstract class Window
    @x : Int32 = 0
    @y : Int32 = 0
    @width : Int32 = 0
    @height : Int32 = 0
    @z_index : Int32 = 0
    property x, y, width, height, z_index

    abstract def render(buffer, width, height)

    def <=>(other)
      self.z_index <=> other.z_index
    end
  end

  class Background < Window
    def initialize(width, height, @color : UInt32)
      self.width = width.to_i32
      self.height = height.to_i32
      self.z_index = -1
    end

    def render(buffer, width, height)
      Wm::Painter.blit_u32(buffer, @color, width.to_u32 * height.to_u32)
    end
  end

  class Cursor < Window
    @bytes : Bytes? = nil
    def initialize
      image = Painter.load_png(CURSOR_FILE).not_nil!
      self.width = image.width
      self.height = image.height
      self.z_index = Int32::MAX
      @bytes = image.bytes
    end

    def render(buffer, bwidth, bheight)
      Wm::Painter.blit_img(buffer, bwidth, bheight,
                           @bytes.not_nil!.to_unsafe,
                           width, height, x, y)
    end

    def respond(file)
      packet = LibC::MousePacket.new
      file.read(Bytes.new(pointerof(packet).as(UInt8*), sizeof(LibC::MousePacket)))
      speed = Math.log2(packet.x + packet.y)
      if packet.x != 0
        delta_x = packet.x * speed
        self.x = self.x + delta_x
        self.x = self.x.clamp(0, Wm.screen_width)
      else
        delta_x = 0
      end
      if packet.y != 0
        delta_y = -packet.y * speed
        self.y = self.y + delta_y
        self.y = self.y.clamp(0, Wm.screen_height)
      else
        delta_y = 0
      end
    end
  end

  class Program < Window
    def initialize(x, y, width, height)
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    end

    def render(buffer, dw, dh)
      Wm::Painter.blit_rect buffer,
        dw, dh,
        self.width, self.height,
        self.x, self.y, 0x00ff0000u32
    end
  end

  @@framebuffer = Pointer(UInt32).null
  @@backbuffer = Pointer(UInt32).null
  def fb
    @@fb.not_nil!
  end

  @@windows = Array(Window).new 4
  @@focused : Window?

  # display size information
  @@ws = uninitialized LibC::Winsize
  def screen_width
    @@ws.ws_col.to_i32
  end
  def screen_height
    @@ws.ws_row.to_i32
  end

  # io selection
  @@selector : IO::Select? = nil
  private def selector
    @@selector.not_nil!
  end

  # raw mouse hardware file
  @@mouse : File? = nil
  private def mouse
    @@mouse.not_nil!
  end

  # window representing the cursor
  @@cursor : Cursor? = nil
  private def cursor
    @@cursor.not_nil!
  end

  # communication pipes
  @@pipe : IO::Pipe? = nil
  private def pipe
    @@pipe.not_nil!
  end

  def _init
    unless (@@fb = File.new("/fb0", "r"))
      abort "unable to open /fb0"
    end
    @@selector = IO::Select.new
    LibC._ioctl fb.fd, LibC::TIOCGWINSZ, pointerof(@@ws).address
    @@framebuffer = fb.map_to_memory.as(UInt32*)
    @@backbuffer = Pointer(UInt32).malloc(screen_width * screen_height)

    @@focused = nil

    # communication pipe
    if (@@pipe = IO::Pipe.new("wm", "r",
        IO::Pipe::Flags::M_Read | IO::Pipe::Flags::G_Write))
      selector << pipe
    else
      abort "unable to create communication pipe"
    end

    # wallpaper
    @@windows.push Background.new(@@ws.ws_col,
                                  @@ws.ws_row,
                                  0x000066cc)

    # mouse
    if (@@mouse = File.new("/mouse/raw", "r"))
      selector << mouse
    else
      abort "unable to open /mouse/raw"
    end
    @@cursor = Cursor.new
    @@windows.push cursor

    # default startup application
    Process.new "windem"
  end
  
  def loop
    while true
      case selector.wait(1)
      when mouse
        cursor.respond mouse
      when pipe
        respond_pipe
      end
      @@windows.each do |window|
        window.render @@backbuffer,
                      @@ws.ws_col,
                      @@ws.ws_row
      end
      LibC.memcpy @@framebuffer,
                  @@backbuffer,
                  (screen_width * screen_height * 4)
      usleep FRAME_WAIT
    end
  end

  private macro enforce_length(t)
    if header.value.length != (sizeof({{ t }}) - sizeof(IPC::Data::Header))
      pipe_buffer += sizeof(IPC::Data::Header)
      pipe_buffer += header.value.length
      next
    end
  end

  @@pipe_buffer = Bytes.empty
  def respond_pipe
    if pipe.size > @@pipe_buffer.size
      @@pipe_buffer = Bytes.new pipe.size
    end
    pipe.unbuffered_read @@pipe_buffer
    pipe_buffer = @@pipe_buffer
    while IPC.valid_msg?(pipe_buffer)
      header = IPC.header_part pipe_buffer
      case header.value.type
      when IPC::Data::TEST_MESSAGE_ID
        STDERR.puts "test message!"
      when IPC::Data::WINDOW_CREATE_ID
        enforce_length(IPC::Data::WindowCreate)
        wc = IPC.payload_part(IPC::Data::WindowCreate,
                              pipe_buffer)
        STDERR.print("wc: ",
          wc.x, " ", wc.y, " ",
          wc.width, " ", wc.height, "\n")
        @@windows.push Program
          .new(wc.x, wc.y, wc.width, wc.height)
        @@windows.sort!
      end
      pipe_buffer += sizeof(IPC::Data::Header)
      pipe_buffer += header.value.length
    end
  end

end

Wm._init
Wm.loop
