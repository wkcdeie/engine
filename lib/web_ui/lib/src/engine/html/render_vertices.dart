// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

part of engine;

_GlRenderer? _glRenderer;

class SurfaceVertices implements ui.Vertices {
  final ui.VertexMode _mode;
  final Float32List _positions;
  final Int32List? _colors;
  final Uint16List? _indices; // ignore: unused_field

  SurfaceVertices(
    ui.VertexMode mode,
    List<ui.Offset> positions, {
    List<ui.Color>? colors,
    List<int>? indices,
  })  : assert(mode != null), // ignore: unnecessary_null_comparison
        assert(positions != null), // ignore: unnecessary_null_comparison
        _mode = mode,
        _colors = colors != null ? _int32ListFromColors(colors) : null,
        _indices = indices != null ? Uint16List.fromList(indices) : null,
        _positions = offsetListToFloat32List(positions) {
    initWebGl();
  }

  SurfaceVertices.raw(
    ui.VertexMode mode,
    Float32List positions, {
    Int32List? colors,
    Uint16List? indices,
  })  : assert(mode != null), // ignore: unnecessary_null_comparison
        assert(positions != null), // ignore: unnecessary_null_comparison
        _mode = mode,
        _positions = positions,
        _colors = colors,
        _indices = indices {
    initWebGl();
  }

  static Int32List _int32ListFromColors(List<ui.Color> colors) {
    Int32List list = Int32List(colors.length);
    for (int i = 0, len = colors.length; i < len; i++) {
      list[i] = colors[i].value;
    }
    return list;
  }
}

/// Lazily initializes web gl.
///
/// Used to treeshake WebGlRenderer when user doesn't create Vertices object
/// to use the API.
void initWebGl() {
  _glRenderer ??= _WebGlRenderer();
}

void disposeWebGl() {
  _GlContextCache.dispose();
  _glRenderer = null;
}

abstract class _GlRenderer {
  void drawVertices(
      html.CanvasRenderingContext2D? context,
      int canvasWidthInPixels,
      int canvasHeightInPixels,
      Matrix4 transform,
      SurfaceVertices vertices,
      ui.BlendMode blendMode,
      SurfacePaintData paint);

  Object? drawRect(ui.Rect targetRect, GlContext gl, GlProgram glProgram,
      NormalizedGradient gradient, int widthInPixels, int heightInPixels);

  String drawRectToImageUrl(ui.Rect targetRect, GlContext gl, GlProgram glProgram,
      NormalizedGradient gradient, int widthInPixels, int heightInPixels);

  void drawHairline(html.CanvasRenderingContext2D? _ctx, Float32List positions);
}

/// Treeshakeable backend for rendering webgl on canvas.
///
/// This class gets instantiated on demand by Vertices constructor. For apps
/// that don't use Vertices WebGlRenderer will be removed from release binary.
class _WebGlRenderer implements _GlRenderer {

  /// Cached vertex shader reused by [drawVertices] and gradients.
  static String? _textureVertexShader;

  static void _setupVertexTransforms(GlContext gl, GlProgram glProgram,
      double offsetX, double offsetY, double widthInPixels,
      double heightInPixels, Matrix4 transform) {
    Object transformUniform = gl.getUniformLocation(glProgram.program,
        'u_ctransform');
    Matrix4 transformAtOffset = transform.clone()
      ..translate(-offsetX, -offsetY);
    gl.setUniformMatrix4fv(transformUniform, false, transformAtOffset.storage);

    // Set uniform to scale 0..width/height pixels coordinates to -1..1
    // clipspace range and flip the Y axis.
    Object resolution = gl.getUniformLocation(glProgram.program, 'u_scale');
    gl.setUniform4f(resolution, 2.0 / widthInPixels.toDouble(),
        -2.0 / heightInPixels.toDouble(), 1, 1);
    Object shift = gl.getUniformLocation(glProgram.program, 'u_shift');
    gl.setUniform4f(shift, -1, 1, 0, 0);
  }

  static void _setupTextureScalar(GlContext gl, GlProgram glProgram,
      double sx, double sy) {
    Object scalar = gl.getUniformLocation(glProgram.program, 'u_texscale');
    gl.setUniform2f(scalar, sx, sy);
  }

  static dynamic _tileModeToGlWrapping(GlContext gl, ui.TileMode tileMode) {
    switch(tileMode) {
      case ui.TileMode.clamp:
        return gl.kClampToEdge;
      case ui.TileMode.decal:
        return gl.kClampToEdge;
      case ui.TileMode.mirror:
        return gl.kMirroredRepeat;
      case ui.TileMode.repeated:
        return gl.kRepeat;
    }
  }

  @override
  void drawVertices(
      html.CanvasRenderingContext2D? context,
      int canvasWidthInPixels,
      int canvasHeightInPixels,
      Matrix4 transform,
      SurfaceVertices vertices,
      ui.BlendMode blendMode,
      SurfacePaintData paint) {

    // Compute bounds of vertices.
    final Float32List positions = vertices._positions;
    ui.Rect bounds = _computeVerticesBounds(positions, transform);
    double minValueX = bounds.left;
    double minValueY = bounds.top;
    double maxValueX = bounds.right;
    double maxValueY = bounds.bottom;
    double offsetX = 0;
    double offsetY = 0;
    int widthInPixels = canvasWidthInPixels;
    int heightInPixels = canvasHeightInPixels;
    // If vertices fall outside the bitmap area, cull.
    if (maxValueX < 0 || maxValueY < 0) {
      return;
    }
    if (minValueX > widthInPixels || minValueY > heightInPixels) {
      return;
    }
    // If Vertices are is smaller than hosting canvas, allocate minimal
    // offscreen canvas to reduce readPixels data size.
    if ((maxValueX - minValueX) < widthInPixels &&
        (maxValueY - minValueY) < heightInPixels) {
      widthInPixels = maxValueX.ceil() - minValueX.floor();
      heightInPixels = maxValueY.ceil() - minValueY.floor();
      offsetX = minValueX.floor().toDouble();
      offsetY = minValueY.floor().toDouble();
    }
    if (widthInPixels == 0 || heightInPixels == 0) {
      return;
    }

    final bool isWebGl2 = webGLVersion == WebGLVersion.webgl2;

    final EngineImageShader? imageShader = paint.shader == null ? null
        : paint.shader as EngineImageShader;

    final String vertexShader = imageShader == null
        ? VertexShaders.writeBaseVertexShader() : writeTextureVertexShader();
    final String fragmentShader = imageShader == null
        ? _writeVerticesFragmentShader()
        : _writeVerticesTextureFragmentShader(isWebGl2,
        imageShader.tileModeX, imageShader.tileModeY);

    GlContext gl = _GlContextCache.createGlContext(widthInPixels, heightInPixels)!;

    GlProgram glProgram = gl.cacheProgram(vertexShader, fragmentShader);
    gl.useProgram(glProgram);

    Object? positionAttributeLocation =
        gl.getAttributeLocation(glProgram.program, 'position');

    _setupVertexTransforms(gl, glProgram, offsetX, offsetY,
        widthInPixels.toDouble(), heightInPixels.toDouble(),
        transform);

    if (imageShader != null) {
      /// To map from vertex position to texture coordinate in 0..1 range,
      /// we setup scalar to be used in vertex shader.
      _setupTextureScalar(gl, glProgram, 1.0 / imageShader._image.width.toDouble(),
          1.0 / imageShader._image.height.toDouble());
    }

    // Setup geometry.
    //
    // Create buffer for vertex coordinates.
    Object positionsBuffer = gl.createBuffer()!;
    assert(positionsBuffer != null); // ignore: unnecessary_null_comparison

    Object? vao;
    if (imageShader != null) {
      if (isWebGl2) {
        // Create a vertex array object.
        vao = gl.createVertexArray();
        // Set vertex array object as active one.
        gl.bindVertexArray(vao!);
      }
    }
    // Turn on position attribute.
    gl.enableVertexAttribArray(positionAttributeLocation);
    // Bind buffer as position buffer and transfer data.
    gl.bindArrayBuffer(positionsBuffer);
    gl.bufferData(positions, gl.kStaticDraw);
    // Setup data format for attribute.
    js_util.callMethod(
        gl.glContext, 'vertexAttribPointer', <dynamic>[
      positionAttributeLocation, 2, gl.kFloat, false, 0, 0,
    ]);

    final int vertexCount = positions.length ~/ 2;
    Object? texture;

    if (imageShader == null) {
      // Setup color buffer.
      Object? colorsBuffer = gl.createBuffer();
      gl.bindArrayBuffer(colorsBuffer);

      // Buffer kBGRA_8888.
      if (vertices._colors == null) {
        final ui.Color color = paint.color ?? ui.Color(0xFF000000);
        Uint32List vertexColors = Uint32List(vertexCount);
        for (int i = 0; i < vertexCount; i++) {
          vertexColors[i] = color.value;
        }
        gl.bufferData(vertexColors, gl.kStaticDraw);
      } else {
        gl.bufferData(vertices._colors, gl.kStaticDraw);
      }
      Object colorLoc = gl.getAttributeLocation(glProgram.program, 'color');
      js_util.callMethod(gl.glContext, 'vertexAttribPointer',
          <dynamic>[colorLoc, 4, gl.kUnsignedByte, true, 0, 0]);
      gl.enableVertexAttribArray(colorLoc);
    } else {
      // Copy image it to the texture.
      texture = gl.createTexture();
      // Texture units are a global array of references to the textures.
      // By setting activeTexture, we associate the bound texture to a unit.
      // Every time we call a texture function such as texImage2D with a target
      // like TEXTURE_2D, it looks up texture by using the currently active
      // unit.
      // In our case we have a single texture unit 0.
      gl.activeTexture(gl.kTexture0);
      gl.bindTexture(gl.kTexture2D, texture);

      gl.texImage2D(
          gl.kTexture2D,
          0,
          gl.kRGBA,
          gl.kRGBA,
          gl.kUnsignedByte,
          imageShader._image.imgElement
      );

      if (isWebGl2) {
        // Texture REPEAT and MIRROR is only supported in WebGL 2, for
        // WebGL 1.0 we let shader compute correct uv coordinates.
        gl.texParameteri(gl.kTexture2D, gl.kTextureWrapS,
            _tileModeToGlWrapping(gl, imageShader.tileModeX));

        gl.texParameteri(gl.kTexture2D, gl.kTextureWrapT,
            _tileModeToGlWrapping(gl, imageShader.tileModeY));

        // Mipmapping saves your texture in different resolutions
        // so the graphics card can choose which resolution is optimal
        // without artifacts.
        gl.generateMipmap(gl.kTexture2D);
      } else {
        // For webgl1, if a texture is not mipmap complete, then the return
        // value of a texel fetch is (0, 0, 0, 1), so we have to set
        // minifying function to filter.
        // See https://www.khronos.org/registry/webgl/specs/1.0.0/#5.13.8.
        gl.texParameteri(gl.kTexture2D, gl.kTextureWrapS,
            gl.kClampToEdge);
        gl.texParameteri(gl.kTexture2D, gl.kTextureWrapT,
            gl.kClampToEdge);
        gl.texParameteri(gl.kTexture2D, gl.kTextureMinFilter, gl.kLinear);
      }
    }

    // Finally render triangles.
    gl.clear();

    final Uint16List ?indices = vertices._indices;
    if (indices == null) {
      gl.drawTriangles(vertexCount, vertices._mode);
    } else {
      /// If indices are specified to use shared vertices to reduce vertex
      /// data transfer, use drawElements to map from vertex indices to
      /// triangles.
      Object? indexBuffer = gl.createBuffer();
      gl.bindElementArrayBuffer(indexBuffer);
      gl.bufferElementData(indices, gl.kStaticDraw);
      gl.drawElements(gl.kTriangles, indices.length, gl.kUnsignedShort);
    }

    if (vao != null) {
      gl.unbindVertexArray();
    }

    context!.save();
    context.resetTransform();
    gl.drawImage(context, offsetX, offsetY);
    context.restore();
  }

  static final Uint16List _vertexIndicesForRect = Uint16List.fromList(
      <int>[
        0, 1, 2, 2, 3, 0
      ]
  );

  /// Renders a rectangle using given program into an image resource.
  ///
  /// Browsers that support OffscreenCanvas and the transferToImageBitmap api
  /// will return ImageBitmap, otherwise will return CanvasElement.
  Object? drawRect(ui.Rect targetRect, GlContext gl, GlProgram glProgram,
      NormalizedGradient gradient, int widthInPixels, int heightInPixels) {
    drawRectToGl(targetRect, gl, glProgram, gradient, widthInPixels, heightInPixels);
    Object? image = gl.readPatternData();
    gl.bindArrayBuffer(null);
    gl.bindElementArrayBuffer(null);
    return image;
  }

  /// Renders a rectangle using given program into an image resource and returns
  /// url.
  String drawRectToImageUrl(ui.Rect targetRect, GlContext gl, GlProgram glProgram,
      NormalizedGradient gradient, int widthInPixels, int heightInPixels) {
    drawRectToGl(targetRect, gl, glProgram, gradient, widthInPixels, heightInPixels);
    final String imageUrl = gl.toImageUrl();
    // Cleanup buffers.
    gl.bindArrayBuffer(null);
    gl.bindElementArrayBuffer(null);
    return imageUrl;
  }

  /// Renders a rectangle using given program into [GlContext].
  ///
  /// Caller has to cleanup gl array and element array buffers.
  void drawRectToGl(ui.Rect targetRect, GlContext gl, GlProgram glProgram,
      NormalizedGradient gradient, int widthInPixels, int heightInPixels) {
    // Setup rectangle coordinates.
    final double left = targetRect.left;
    final double top = targetRect.top;
    final double right = targetRect.right;
    final double bottom = targetRect.bottom;
    // Form 2 triangles for rectangle.
    final Float32List vertices = Float32List(8);
    vertices[0] = left;
    vertices[1] = top;
    vertices[2] = right;
    vertices[3] = top;
    vertices[4] = right;
    vertices[5] = bottom;
    vertices[6] = left;
    vertices[7] = bottom;

    Object transformUniform = gl.getUniformLocation(
        glProgram.program, 'u_ctransform');
    gl.setUniformMatrix4fv(transformUniform, false, Matrix4.identity().storage);

    // Set uniform to scale 0..width/height pixels coordinates to -1..1
    // clipspace range and flip the Y axis.
    Object resolution = gl.getUniformLocation(glProgram.program, 'u_scale');
    gl.setUniform4f(resolution, 2.0 / widthInPixels.toDouble(),
        -2.0 / heightInPixels.toDouble(), 1, 1);
    Object shift = gl.getUniformLocation(glProgram.program, 'u_shift');
    gl.setUniform4f(shift, -1, 1, 0, 0);

    // Setup geometry.
    Object positionsBuffer = gl.createBuffer()!;
    assert(positionsBuffer != null); // ignore: unnecessary_null_comparison
    gl.bindArrayBuffer(positionsBuffer);
    gl.bufferData(vertices, gl.kStaticDraw);
    // Point an attribute to the currently bound vertex buffer object.
    js_util.callMethod(
        gl.glContext, 'vertexAttribPointer',
        <dynamic>[0, 2, gl.kFloat, false, 0, 0]);
    gl.enableVertexAttribArray(0);

    // Setup color buffer.
    Object? colorsBuffer = gl.createBuffer();
    gl.bindArrayBuffer(colorsBuffer);
    // Buffer kBGRA_8888.
    final Int32List colors = Int32List.fromList(<int>[
      0xFF00FF00, 0xFF0000FF, 0xFFFFFF00, 0xFF00FFFF,
    ]);
    gl.bufferData(colors, gl.kStaticDraw);
    js_util.callMethod(gl.glContext, 'vertexAttribPointer',
        <dynamic>[1, 4, gl.kUnsignedByte, true, 0, 0]);
    gl.enableVertexAttribArray(1);

    Object? indexBuffer = gl.createBuffer();
    gl.bindElementArrayBuffer(indexBuffer);
    gl.bufferElementData(_vertexIndicesForRect, gl.kStaticDraw);

    if (gl.containsUniform(glProgram.program, 'u_resolution')) {
      Object uRes = gl.getUniformLocation(glProgram.program, 'u_resolution');
      gl.setUniform2f(
          uRes, widthInPixels.toDouble(), heightInPixels.toDouble());
    }

    gl.clear();
    gl.viewport(0, 0, widthInPixels.toDouble(), heightInPixels.toDouble());

    gl.drawElements(gl.kTriangles, _vertexIndicesForRect.length, gl.kUnsignedShort);
  }

   static String writeTextureVertexShader() {
    if (_textureVertexShader == null) {
      ShaderBuilder builder = ShaderBuilder(webGLVersion);
      builder.addIn(ShaderType.kVec4, name: 'position');
      builder.addUniform(ShaderType.kMat4, name: 'u_ctransform');
      builder.addUniform(ShaderType.kVec4, name: 'u_scale');
      builder.addUniform(ShaderType.kVec2, name: 'u_texscale');
      builder.addUniform(ShaderType.kVec4, name: 'u_shift');
      builder.addOut(ShaderType.kVec2, name: 'v_texcoord');
      ShaderMethod method = builder.addMethod('main');
      method.addStatement(
          'gl_Position = ((u_ctransform * position) * u_scale) + u_shift;');
      method.addStatement(
          'v_texcoord = vec2(position.x * u_texscale.x, '
          '(position.y * u_texscale.y));');
      _textureVertexShader = builder.build();
    }
    return _textureVertexShader!;
  }

  /// This fragment shader enables Int32List of colors to be passed directly
  /// to gl context buffer for rendering by decoding RGBA8888.
  ///     #version 300 es
  ///     precision mediump float;
  ///     in vec4 vColor;
  ///     out vec4 fragColor;
  ///     void main() {
  ///       fragColor = vColor;
  ///     }
  String _writeVerticesFragmentShader() {
    ShaderBuilder builder = ShaderBuilder.fragment(webGLVersion);
    builder.floatPrecision = ShaderPrecision.kMedium;
    builder.addIn(ShaderType.kVec4, name:'v_color');
    ShaderMethod method = builder.addMethod('main');
    method.addStatement('${builder.fragmentColor.name} = v_color;');
    return builder.build();
  }

  String _writeVerticesTextureFragmentShader(bool isWebGl2,
      ui.TileMode? tileModeX, ui.TileMode? tileModeY) {
    ShaderBuilder builder = ShaderBuilder.fragment(webGLVersion);
    builder.floatPrecision = ShaderPrecision.kMedium;
    builder.addIn(ShaderType.kVec2, name:'v_texcoord');
    builder.addUniform(ShaderType.kSampler2D, name: 'u_texture');
    ShaderMethod method = builder.addMethod('main');
    if (isWebGl2
        || tileModeX == null || tileModeY == null
        || (tileModeX == ui.TileMode.clamp && tileModeY == ui.TileMode.clamp)) {
      method.addStatement('${builder.fragmentColor.name} = '
          '${builder.texture2DFunction}(u_texture, v_texcoord);');
    } else {
      // Repeat and mirror are not supported for webgl1. Write code to
      // adjust texture coordinate.
      //
      // This will write u and v floats, clamp/repeat and mirror the value and
      // pass it to sampler.
      method.addTileStatements('v_texcoord.x', 'u', tileModeX);
      method.addTileStatements('v_texcoord.y', 'v', tileModeY);
      method.addStatement('vec2 uv = vec2(u, v);');
      method.addStatement('${builder.fragmentColor.name} = '
          '${builder.texture2DFunction}(u_texture, uv);');
    }
    return builder.build();
  }

  @override
  void drawHairline(html.CanvasRenderingContext2D? _ctx, Float32List positions) {
    assert(positions != null); // ignore: unnecessary_null_comparison
    final int pointCount = positions.length ~/ 2;
    _ctx!.lineWidth = 1.0;
    _ctx.beginPath();
    for (int i = 0, len = pointCount * 2; i < len;) {
      for (int triangleVertexIndex = 0;
          triangleVertexIndex < 3;
          triangleVertexIndex++, i += 2) {
        final double dx = positions[i];
        final double dy = positions[i + 1];
        switch (triangleVertexIndex) {
          case 0:
            _ctx.moveTo(dx, dy);
            break;
          case 1:
            _ctx.lineTo(dx, dy);
            break;
          case 2:
            _ctx.lineTo(dx, dy);
            _ctx.closePath();
            _ctx.stroke();
        }
      }
    }
  }
}

ui.Rect _computeVerticesBounds(Float32List positions, Matrix4 transform) {
  double minValueX, maxValueX, minValueY, maxValueY;
  minValueX = maxValueX = positions[0];
  minValueY = maxValueY = positions[1];
  for (int i = 2, len = positions.length; i < len; i += 2) {
    final double x = positions[i];
    final double y = positions[i + 1];
    if (x.isNaN || y.isNaN) {
      // Follows skia implementation that sets bounds to empty
      // and aborts.
      return ui.Rect.zero;
    }
    minValueX = math.min(minValueX, x);
    maxValueX = math.max(maxValueX, x);
    minValueY = math.min(minValueY, y);
    maxValueY = math.max(maxValueY, y);
  }
  return _transformBounds(
      transform, minValueX, minValueY, maxValueX, maxValueY);
}

ui.Rect _transformBounds(
    Matrix4 transform, double left, double top, double right, double bottom) {
  final Float32List storage = transform.storage;
  final double m0 = storage[0];
  final double m1 = storage[1];
  final double m4 = storage[4];
  final double m5 = storage[5];
  final double m12 = storage[12];
  final double m13 = storage[13];
  final double x0 = (m0 * left) + (m4 * top) + m12;
  final double y0 = (m1 * left) + (m5 * top) + m13;
  final double x1 = (m0 * right) + (m4 * top) + m12;
  final double y1 = (m1 * right) + (m5 * top) + m13;
  final double x2 = (m0 * right) + (m4 * bottom) + m12;
  final double y2 = (m1 * right) + (m5 * bottom) + m13;
  final double x3 = (m0 * left) + (m4 * bottom) + m12;
  final double y3 = (m1 * left) + (m5 * bottom) + m13;
  return ui.Rect.fromLTRB(
      math.min(x0, math.min(x1, math.min(x2, x3))),
      math.min(y0, math.min(y1, math.min(y2, y3))),
      math.max(x0, math.max(x1, math.max(x2, x3))),
      math.max(y0, math.max(y1, math.max(y2, y3))));
}

// Converts from [VertexMode] triangleFan and triangleStrip to triangles.
Float32List _convertVertexPositions(ui.VertexMode mode, Float32List positions) {
  assert(mode != ui.VertexMode.triangles);
  if (mode == ui.VertexMode.triangleFan) {
    final int coordinateCount = positions.length ~/ 2;
    final int triangleCount = coordinateCount - 2;
    final Float32List triangleList = Float32List(triangleCount * 3 * 2);
    double centerX = positions[0];
    double centerY = positions[1];
    int destIndex = 0;
    int positionIndex = 2;
    for (int triangleIndex = 0;
        triangleIndex < triangleCount;
        triangleIndex++, positionIndex += 2) {
      triangleList[destIndex++] = centerX;
      triangleList[destIndex++] = centerY;
      triangleList[destIndex++] = positions[positionIndex];
      triangleList[destIndex++] = positions[positionIndex + 1];
      triangleList[destIndex++] = positions[positionIndex + 2];
      triangleList[destIndex++] = positions[positionIndex + 3];
    }
    return triangleList;
  } else {
    assert(mode == ui.VertexMode.triangleStrip);
    // Set of connected triangles. Each triangle shares 2 last vertices.
    final int vertexCount = positions.length ~/ 2;
    int triangleCount = vertexCount - 2;
    double x0 = positions[0];
    double y0 = positions[1];
    double x1 = positions[2];
    double y1 = positions[3];
    final Float32List triangleList = Float32List(triangleCount * 3 * 2);
    int destIndex = 0;
    for (int i = 0, positionIndex = 4; i < triangleCount; i++) {
      final double x2 = positions[positionIndex++];
      final double y2 = positions[positionIndex++];
      triangleList[destIndex++] = x0;
      triangleList[destIndex++] = y0;
      triangleList[destIndex++] = x1;
      triangleList[destIndex++] = y1;
      triangleList[destIndex++] = x2;
      triangleList[destIndex++] = y2;
      x0 = x1;
      y0 = y1;
      x1 = x2;
      y1 = y2;
    }
    return triangleList;
  }
}

/// Compiled and cached gl program.
class GlProgram {
  final Object program;
  GlProgram(this.program);
}

/// JS Interop helper for webgl apis.
class GlContext {
  final Object glContext;
  final bool isOffscreen;
  dynamic _kCompileStatus;
  dynamic _kArrayBuffer;
  dynamic _kElementArrayBuffer;
  dynamic _kStaticDraw;
  dynamic _kFloat;
  dynamic _kColorBufferBit;
  dynamic _kTexture2D;
  dynamic _kTextureWrapS;
  dynamic _kTextureWrapT;
  dynamic _kRepeat;
  dynamic _kClampToEdge;
  dynamic _kMirroredRepeat;
  dynamic _kTriangles;
  dynamic _kLinkStatus;
  dynamic _kUnsignedByte;
  dynamic _kUnsignedShort;
  dynamic _kRGBA;
  dynamic _kLinear;
  dynamic _kTextureMinFilter;
  int? _kTexture0;

  Object? _canvas;
  int? _widthInPixels;
  int? _heightInPixels;
  static late Map<String, GlProgram?> _programCache;

  GlContext.fromOffscreenCanvas(html.OffscreenCanvas canvas)
      : glContext = canvas.getContext('webgl2', <String, dynamic>{'premultipliedAlpha': false})!,
        isOffscreen = true {
    _programCache = <String, GlProgram?>{};
    _canvas = canvas;
  }

  GlContext.fromCanvas(html.CanvasElement canvas, bool useWebGl1)
      : glContext = canvas.getContext(useWebGl1 ? 'webgl' : 'webgl2',
      <String, dynamic>{'premultipliedAlpha': false})!,
        isOffscreen = false {
    _programCache = <String, GlProgram?>{};
    _canvas = canvas;
  }

  void setViewportSize(int width, int height) {
    _widthInPixels = width;
    _heightInPixels = height;
  }

  /// Draws Gl context contents to canvas context.
  void drawImage(html.CanvasRenderingContext2D context,
      double left, double top) {
    // Actual size of canvas may be larger than viewport size. Use
    // source/destination to draw part of the image data.
    js_util.callMethod(context, 'drawImage',
        <dynamic>[_canvas, 0, 0, _widthInPixels, _heightInPixels,
          left, top, _widthInPixels, _heightInPixels]);
  }

  GlProgram cacheProgram(
      String vertexShaderSource, String fragmentShaderSource) {
    String cacheKey = '$vertexShaderSource||$fragmentShaderSource';
    GlProgram? cachedProgram = _programCache[cacheKey];
    if (cachedProgram == null) {
      // Create and compile shaders.
      Object vertexShader = compileShader('VERTEX_SHADER', vertexShaderSource);
      Object fragmentShader =
      compileShader('FRAGMENT_SHADER', fragmentShaderSource);
      // Create a gl program and link shaders.
      Object program = createProgram();
      attachShader(program, vertexShader);
      attachShader(program, fragmentShader);
      linkProgram(program);
      cachedProgram = GlProgram(program);
      _programCache[cacheKey] = cachedProgram;
    }
    return cachedProgram;
  }

  Object compileShader(String shaderType, String source) {
    Object? shader = _createShader(shaderType);
    if (shader == null) {
      throw Exception(error);
    }
    js_util.callMethod(glContext, 'shaderSource', <dynamic>[shader, source]);
    js_util.callMethod(glContext, 'compileShader', <dynamic>[shader]);
    bool shaderStatus = js_util
        .callMethod(glContext, 'getShaderParameter', <dynamic>[shader, compileStatus]);
    if (!shaderStatus) {
      throw Exception('Shader compilation failed: ${getShaderInfoLog(shader)}');
    }
    return shader;
  }

  Object createProgram() =>
      js_util.callMethod(glContext, 'createProgram', const <dynamic>[])!;

  void attachShader(Object? program, Object shader) {
    js_util.callMethod(glContext, 'attachShader', <dynamic>[program, shader]);
  }

  void linkProgram(Object program) {
    js_util.callMethod(glContext, 'linkProgram', <dynamic>[program]);
    if (!js_util
        .callMethod(glContext, 'getProgramParameter', <dynamic>[program, kLinkStatus])) {
      throw Exception(getProgramInfoLog(program));
    }
  }

  void useProgram(GlProgram program) {
    js_util.callMethod(glContext, 'useProgram', <dynamic>[program.program]);
  }

  Object? createBuffer() =>
      js_util.callMethod(glContext, 'createBuffer', const <dynamic>[]);

  void bindArrayBuffer(Object? buffer) {
    js_util.callMethod(glContext, 'bindBuffer', <dynamic>[kArrayBuffer, buffer]);
  }

  Object? createVertexArray() =>
      js_util.callMethod(glContext, 'createVertexArray', const <dynamic>[]);

  void bindVertexArray(Object vertexObjectArray) {
    js_util.callMethod(glContext, 'bindVertexArray',
        <dynamic>[vertexObjectArray]);
  }

  void unbindVertexArray() {
    js_util.callMethod(glContext, 'bindVertexArray',
        <dynamic>[null]);
  }

  void bindElementArrayBuffer(Object? buffer) {
    js_util.callMethod(glContext, 'bindBuffer', <dynamic>[kElementArrayBuffer, buffer]);
  }

  Object? createTexture() =>
      js_util.callMethod(glContext, 'createTexture', const <dynamic>[]);

  void generateMipmap(dynamic target) =>
      js_util.callMethod(glContext, 'generateMipmap', <dynamic>[target]);

  void bindTexture(dynamic target, Object? buffer) {
    js_util.callMethod(glContext, 'bindTexture', <dynamic>[target, buffer]);
  }

  void activeTexture(int textureUnit) {
    js_util.callMethod(glContext, 'activeTexture', <dynamic>[textureUnit]);
  }

  void texImage2D(dynamic target, int level, dynamic internalFormat,
      dynamic format, dynamic dataType,
      dynamic pixels, {int? width, int? height, int border = 0}) {
    if (width == null) {
      js_util.callMethod(glContext, 'texImage2D', <dynamic>[
        target, level, internalFormat, format, dataType, pixels]);
    } else {
      js_util.callMethod(glContext, 'texImage2D', <dynamic>[
        target, level, internalFormat, width, height, border, format, dataType,
        pixels]);
    }
  }

  void texParameteri(dynamic target, dynamic parameterName, dynamic value) {
    js_util.callMethod(glContext, 'texParameteri', <dynamic>[
      target, parameterName, value]);
  }

  void deleteBuffer(Object buffer) {
    js_util.callMethod(glContext, 'deleteBuffer', <dynamic>[buffer]);
  }

  void bufferData(TypedData? data, dynamic type) {
    js_util.callMethod(glContext, 'bufferData', <dynamic>[kArrayBuffer, data, type]);
  }

  void bufferElementData(TypedData? data, dynamic type) {
    js_util.callMethod(glContext, 'bufferData', <dynamic>[kElementArrayBuffer, data, type]);
  }

  void enableVertexAttribArray(dynamic index) {
    js_util.callMethod(glContext, 'enableVertexAttribArray', <dynamic>[index]);
  }

  /// Clear background.
  void clear() {
    js_util.callMethod(glContext, 'clear', <dynamic>[kColorBufferBit]);
  }

  /// Destroys gl context.
  void dispose() {
    js_util.callMethod(_getExtension('WEBGL_lose_context'), 'loseContext', const <dynamic>[]);
  }

  void deleteProgram(Object program) {
    js_util.callMethod(glContext, 'deleteProgram', <dynamic>[program]);
  }

  void deleteShader(Object shader) {
    js_util.callMethod(glContext, 'deleteShader', <dynamic>[shader]);
  }

  dynamic _getExtension(String extensionName) =>
      js_util.callMethod(glContext, 'getExtension', <dynamic>[extensionName]);

  void drawTriangles(int triangleCount, ui.VertexMode vertexMode) {
    dynamic mode = _triangleTypeFromMode(vertexMode);
    js_util.callMethod(glContext, 'drawArrays', <dynamic>[mode, 0, triangleCount]);
  }

  void drawElements(dynamic type, int indexCount, dynamic indexType) {
    js_util.callMethod(glContext, 'drawElements', <dynamic>[type, indexCount, indexType, 0]);
  }

  /// Sets affine transformation from normalized device coordinates
  /// to window coordinates
  void viewport(double x, double y, double width, double height) {
    js_util.callMethod(glContext, 'viewport', <dynamic>[x, y, width, height]);
  }

  dynamic _triangleTypeFromMode(ui.VertexMode mode) {
    switch (mode) {
      case ui.VertexMode.triangles:
        return kTriangles;
      case ui.VertexMode.triangleFan:
        return kTriangleFan;
      case ui.VertexMode.triangleStrip:
        return kTriangleStrip;
    }
  }

  Object? _createShader(String shaderType) => js_util.callMethod(
      glContext, 'createShader', <dynamic>[js_util.getProperty(glContext, shaderType)]);

  /// Error state of gl context.
  dynamic get error => js_util.callMethod(glContext, 'getError', const <dynamic>[]);

  /// Shader compiler error, if this returns [kFalse], to get details use
  /// [getShaderInfoLog].
  dynamic get compileStatus =>
      _kCompileStatus ??= js_util.getProperty(glContext, 'COMPILE_STATUS');

  dynamic get kArrayBuffer =>
      _kArrayBuffer ??= js_util.getProperty(glContext, 'ARRAY_BUFFER');

  dynamic get kElementArrayBuffer =>
      _kElementArrayBuffer ??= js_util.getProperty(glContext,
          'ELEMENT_ARRAY_BUFFER');

  dynamic get kLinkStatus =>
      _kLinkStatus ??= js_util.getProperty(glContext, 'LINK_STATUS');

  dynamic get kFloat => _kFloat ??= js_util.getProperty(glContext, 'FLOAT');

  dynamic get kRGBA => _kRGBA ??= js_util.getProperty(glContext, 'RGBA');

  dynamic get kUnsignedByte =>
      _kUnsignedByte ??= js_util.getProperty(glContext, 'UNSIGNED_BYTE');

  dynamic get kUnsignedShort =>
      _kUnsignedShort ??= js_util.getProperty(glContext, 'UNSIGNED_SHORT');

  dynamic get kStaticDraw =>
      _kStaticDraw ??= js_util.getProperty(glContext, 'STATIC_DRAW');

  dynamic get kTriangles =>
      _kTriangles ??= js_util.getProperty(glContext, 'TRIANGLES');

  dynamic get kTriangleFan =>
      _kTriangles ??= js_util.getProperty(glContext, 'TRIANGLE_FAN');

  dynamic get kTriangleStrip =>
      _kTriangles ??= js_util.getProperty(glContext, 'TRIANGLE_STRIP');

  dynamic get kColorBufferBit =>
      _kColorBufferBit ??= js_util.getProperty(glContext, 'COLOR_BUFFER_BIT');

  dynamic get kTexture2D =>
      _kTexture2D ??= js_util.getProperty(glContext, 'TEXTURE_2D');

  int get kTexture0 =>
      _kTexture0 ??= js_util.getProperty(glContext, 'TEXTURE0') as int;

  dynamic get kTextureWrapS =>
      _kTextureWrapS ??= js_util.getProperty(glContext, 'TEXTURE_WRAP_S');

  dynamic get kTextureWrapT =>
      _kTextureWrapT ??= js_util.getProperty(glContext, 'TEXTURE_WRAP_T');

  dynamic get kRepeat =>
      _kRepeat ??= js_util.getProperty(glContext, 'REPEAT');

  dynamic get kClampToEdge =>
      _kClampToEdge ??= js_util.getProperty(glContext, 'CLAMP_TO_EDGE');

  dynamic get kMirroredRepeat =>
      _kMirroredRepeat ??= js_util.getProperty(glContext, 'MIRRORED_REPEAT');

  dynamic get kLinear =>
      _kLinear ??= js_util.getProperty(glContext, 'LINEAR');

  dynamic get kTextureMinFilter =>
      _kTextureMinFilter ??= js_util.getProperty(glContext,
          'TEXTURE_MIN_FILTER');

  /// Returns reference to uniform in program.
  Object getUniformLocation(Object program, String uniformName) {
    Object? res = js_util
        .callMethod(glContext, 'getUniformLocation', <dynamic>[program, uniformName]);
    if (res == null) {
      throw Exception('$uniformName not found');
    } else {
      return res;
    }
  }

  /// Returns true if uniform exists.
  bool containsUniform(Object program, String uniformName) {
    Object? res = js_util
        .callMethod(glContext, 'getUniformLocation', <dynamic>[program, uniformName]);
    return res != null;
  }

  /// Returns reference to uniform in program.
  Object getAttributeLocation(Object program, String attribName) {
    Object? res = js_util
        .callMethod(glContext, 'getAttribLocation', <dynamic>[program, attribName]);
    if (res == null) {
      throw Exception('$attribName not found');
    } else {
      return res;
    }
  }

  /// Sets float uniform value.
  void setUniform1f(Object uniform, double value) {
    return js_util
        .callMethod(glContext, 'uniform1f', <dynamic>[uniform, value]);
  }

  /// Sets vec2 uniform values.
  void setUniform2f(Object uniform, double value1, double value2) {
    return js_util
        .callMethod(glContext, 'uniform2f', <dynamic>[uniform, value1, value2]);
  }

  /// Sets vec4 uniform values.
  void setUniform4f(Object uniform, double value1, double value2, double value3,
      double value4) {
    return js_util.callMethod(
        glContext, 'uniform4f', <dynamic>[uniform, value1, value2, value3, value4]);
  }

  /// Sets mat4 uniform values.
  void setUniformMatrix4fv(Object uniform, bool transpose, Float32List value) {
    return js_util.callMethod(
        glContext, 'uniformMatrix4fv', <dynamic>[uniform, transpose, value]);
  }

  /// Shader compile error log.
  dynamic getShaderInfoLog(Object glShader) {
    return js_util.callMethod(glContext, 'getShaderInfoLog', <dynamic>[glShader]);
  }

  ///  Errors that occurred during failed linking or validation of program
  ///  objects. Typically called after [linkProgram].
  String? getProgramInfoLog(Object glProgram) {
    return js_util.callMethod(glContext, 'getProgramInfoLog', <dynamic>[glProgram]);
  }

  int? get drawingBufferWidth =>
      js_util.getProperty(glContext, 'drawingBufferWidth');
  int? get drawingBufferHeight =>
      js_util.getProperty(glContext, 'drawingBufferWidth');

  /// Reads gl contents as image data.
  ///
  /// Warning: data is read bottom up (flipped).
  html.ImageData readImageData() {
    const int kBytesPerPixel = 4;
    final int bufferWidth = _widthInPixels!;
    final int bufferHeight = _heightInPixels!;
    if (browserEngine == BrowserEngine.webkit ||
        browserEngine == BrowserEngine.firefox) {
      final Uint8List pixels =
          Uint8List(bufferWidth * bufferHeight * kBytesPerPixel);
      js_util.callMethod(glContext, 'readPixels',
          <dynamic>[0, 0, bufferWidth, bufferHeight, kRGBA, kUnsignedByte, pixels]);
      return html.ImageData(
          Uint8ClampedList.fromList(pixels), bufferWidth, bufferHeight);
    } else {
      final Uint8ClampedList pixels =
          Uint8ClampedList(bufferWidth * bufferHeight * kBytesPerPixel);
      js_util.callMethod(glContext, 'readPixels',
          <dynamic>[0, 0, bufferWidth, bufferHeight, kRGBA, kUnsignedByte, pixels]);
      return html.ImageData(pixels, bufferWidth, bufferHeight);
    }
  }

  /// Returns image data in a form that can be used to create Canvas
  /// context patterns.
  Object? readPatternData() {
    // When using OffscreenCanvas and transferToImageBitmap is supported by
    // browser create ImageBitmap otherwise use more expensive canvas
    // allocation.
    if (_canvas != null &&
        js_util.hasProperty(_canvas!, 'transferToImageBitmap')) {
      js_util.callMethod(_canvas!, 'getContext', <dynamic>['webgl2']);
      Object?imageBitmap = js_util.callMethod(_canvas!, 'transferToImageBitmap',
          <dynamic>[]);
      return imageBitmap;
    } else {
      html.CanvasElement canvas = html.CanvasElement(width: _widthInPixels, height: _heightInPixels);
      final html.CanvasRenderingContext2D ctx = canvas.context2D;
      drawImage(ctx, 0, 0);
      return canvas;
    }
  }

  /// Returns image data in data url format.
  String toImageUrl() {
    html.CanvasElement canvas = html.CanvasElement(width: _widthInPixels, height: _heightInPixels);
    final html.CanvasRenderingContext2D ctx = canvas.context2D;
    drawImage(ctx, 0, 0);
    final String dataUrl = canvas.toDataUrl();
    canvas.width = 0;
    canvas.height = 0;
    return dataUrl;
  }
}

/// Polyfill for html.OffscreenCanvas that is not supported on some browsers.
class _OffScreenCanvas {
  html.OffscreenCanvas? _canvas;
  html.CanvasElement? _glCanvas;
  int width;
  int height;

  _OffScreenCanvas(this.width, this.height) {
    if (_OffScreenCanvas.supported) {
      _canvas = html.OffscreenCanvas(width, height);
    } else {
      _glCanvas = html.CanvasElement(
        width: width,
        height: height,
      );
      _glCanvas!.className = 'gl-canvas';
      final double cssWidth = width / EnginePlatformDispatcher.browserDevicePixelRatio;
      final double cssHeight = height / EnginePlatformDispatcher.browserDevicePixelRatio;
      _glCanvas!.style
        ..position = 'absolute'
        ..width = '${cssWidth}px'
        ..height = '${cssHeight}px';
    }
  }

  void dispose() {
    _canvas = null;
    _glCanvas = null;
  }

  /// Feature detects OffscreenCanvas.
  static bool get supported =>
      js_util.hasProperty(html.window, 'OffscreenCanvas');
}

/// Creates gl context from cached OffscreenCanvas for webgl rendering to image.
class _GlContextCache {
  static int _maxPixelWidth = 0;
  static int _maxPixelHeight = 0;
  static GlContext? _cachedContext;
  static _OffScreenCanvas? _offScreenCanvas;

  static void dispose() {
    _maxPixelWidth = 0;
    _maxPixelHeight = 0;
    _cachedContext = null;
    _offScreenCanvas?.dispose();
  }

  static GlContext? createGlContext(int widthInPixels, int heightInPixels) {
    if (widthInPixels > _maxPixelWidth || heightInPixels > _maxPixelHeight) {
      _cachedContext?.dispose();
      _cachedContext = null;
      _offScreenCanvas = null;
      _maxPixelWidth = math.max(_maxPixelWidth, widthInPixels);
      _maxPixelHeight = math.max(_maxPixelHeight, widthInPixels);
    }
    _offScreenCanvas ??= _OffScreenCanvas(widthInPixels, heightInPixels);
    if (_OffScreenCanvas.supported) {
      _cachedContext ??=
          GlContext.fromOffscreenCanvas(_offScreenCanvas!._canvas!);
    } else {
      _cachedContext ??= GlContext.fromCanvas(_offScreenCanvas!._glCanvas!,
          webGLVersion == WebGLVersion.webgl1);
    }
    _cachedContext!.setViewportSize(widthInPixels, heightInPixels);
    return _cachedContext;
  }
}
