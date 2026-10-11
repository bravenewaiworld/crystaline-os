/*
 * glspin: minimal OpenGL ES 2 test for the Brick's GPU. Draws a spinning triangle on a
 * colour-cycling background and prints frames per second. Uses PowerVR's windowless EGL
 * ("NULL window system": no X or Wayland; a NULL native window means the whole screen), whose
 * frames reach the display through the dc_sunxi.ko module (see tools/build-gpu.sh).
 * Usage: glspin [seconds]   (default 10)
 * Builds without GL headers (the few EGL/GLES declarations it needs are below); link with
 * -lEGL -lGLESv2 from TrimUI's libraries.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

typedef void *EGLDisplay, *EGLConfig, *EGLSurface, *EGLContext;
typedef int EGLint;
typedef unsigned int GLuint, GLenum, GLbitfield;
typedef int GLint, GLsizei;
typedef float GLfloat;
typedef char GLchar;

#define EGL_DEFAULT_DISPLAY	((void *)0)
#define EGL_NONE		0x3038
#define EGL_RED_SIZE		0x3024
#define EGL_GREEN_SIZE		0x3023
#define EGL_BLUE_SIZE		0x3022
#define EGL_RENDERABLE_TYPE	0x3040
#define EGL_OPENGL_ES2_BIT	0x0004
#define EGL_CONTEXT_CLIENT_VERSION 0x3098
#define GL_COLOR_BUFFER_BIT	0x4000
#define GL_TRIANGLES		0x0004
#define GL_FLOAT		0x1406
#define GL_VERTEX_SHADER	0x8B31
#define GL_FRAGMENT_SHADER	0x8B30

EGLDisplay eglGetDisplay(void *);
unsigned eglInitialize(EGLDisplay, EGLint *, EGLint *);
unsigned eglChooseConfig(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
EGLSurface eglCreateWindowSurface(EGLDisplay, EGLConfig, void *, const EGLint *);
EGLContext eglCreateContext(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
unsigned eglMakeCurrent(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
unsigned eglSwapBuffers(EGLDisplay, EGLSurface);
GLuint glCreateShader(GLenum);
void glShaderSource(GLuint, GLsizei, const GLchar *const *, const GLint *);
void glCompileShader(GLuint);
GLuint glCreateProgram(void);
void glAttachShader(GLuint, GLuint);
void glLinkProgram(GLuint);
void glUseProgram(GLuint);
GLint glGetUniformLocation(GLuint, const GLchar *);
void glUniform1f(GLint, GLfloat);
void glVertexAttribPointer(GLuint, GLint, GLenum, unsigned char, GLsizei, const void *);
void glEnableVertexAttribArray(GLuint);
void glClearColor(GLfloat, GLfloat, GLfloat, GLfloat);
void glClear(GLbitfield);
void glDrawArrays(GLenum, GLint, GLsizei);

static const char *vs =
	"attribute vec2 pos; uniform float t;"
	"void main() { float c = cos(t), s = sin(t);"
	"  gl_Position = vec4(c * pos.x - s * pos.y, (s * pos.x + c * pos.y) * 1.333, 0.0, 1.0); }";
	/* 1.333 = 1024/768, so the triangle keeps its shape on the 4:3 screen */
static const char *fs =
	"precision mediump float; void main() { gl_FragColor = vec4(1.0, 0.9, 0.2, 1.0); }";

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static GLuint shader(GLenum type, const char *src)
{
	GLuint s = glCreateShader(type);

	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	return s;
}

int main(int argc, char **argv)
{
	static const EGLint cfg_attr[] = { EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE };
	static const EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	static const GLfloat tri[] = { 0.0f, 0.6f, -0.52f, -0.3f, 0.52f, -0.3f };
	double seconds = argc > 1 ? atof(argv[1]) : 10, start, last;
	EGLDisplay dpy;
	EGLConfig cfg;
	EGLSurface surf;
	EGLint n;
	GLuint prog;
	GLint t_loc;
	int frames = 0;

	dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	if (!eglInitialize(dpy, NULL, NULL) || !eglChooseConfig(dpy, cfg_attr, &cfg, 1, &n) || !n) {
		fprintf(stderr, "EGL setup failed\n");
		return 1;
	}
	surf = eglCreateWindowSurface(dpy, cfg, NULL, NULL);	/* NULL window system: no window */
	eglMakeCurrent(dpy, surf, surf, eglCreateContext(dpy, cfg, NULL, ctx_attr));

	prog = glCreateProgram();
	glAttachShader(prog, shader(GL_VERTEX_SHADER, vs));
	glAttachShader(prog, shader(GL_FRAGMENT_SHADER, fs));
	glLinkProgram(prog);
	glUseProgram(prog);
	t_loc = glGetUniformLocation(prog, "t");
	glVertexAttribPointer(0, 2, GL_FLOAT, 0, 0, tri);
	glEnableVertexAttribArray(0);

	start = now();
	last = 0;
	for (;;) {
		double t = now() - start;

		if (t >= seconds)
			break;
		glClearColor(0.5 + 0.5 * sin(t), 0.5 + 0.5 * sin(t + 2.1), 0.5 + 0.5 * sin(t + 4.2), 1);
		glClear(GL_COLOR_BUFFER_BIT);
		glUniform1f(t_loc, t * 2);
		glDrawArrays(GL_TRIANGLES, 0, 3);
		eglSwapBuffers(dpy, surf);
		frames++;
		if (t - last >= 1) {
			printf("%.1f fps\n", frames / (t - last));
			fflush(stdout);
			frames = 0;
			last = t;
		}
	}
	return 0;
}
