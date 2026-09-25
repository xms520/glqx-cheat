# GLQXCheat — 纯 clang 直接编译（无 theos 依赖，GitHub Actions macos-14 跑）
# 本地: xcrun -sdk iphoneos clang -arch arm64 -dynamiclib ... -o GLQXCheat.dylib GLQXCheat.m
TARGET  = iphone:clang:16.5:15.0
ARCHS   = arm64

GLQXCHEAT_NAME = GLQXCheat

all: $(GLQXCHEAT_NAME).dylib

$(GLQXCHEAT_NAME).dylib: GLQXCheat.m
	clang -arch arm64 \
	  -miphoneos-version-min=15.0 \
	  -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore \
	  -dynamiclib -fobjc-arc -O2 \
	  -o $(GLQXCHEAT_NAME).dylib GLQXCheat.m

clean:
	rm -f $(GLQXCHEAT_NAME).dylib

.PHONY: all clean
