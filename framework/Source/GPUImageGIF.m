#import "GPUImageGIF.h"
#import "GPUImageMovieWriter.h"
#import "GPUImageFilter.h"
#import "GPUImageColorConversion.h"


@interface GPUImageGIF ()
{
    CGFloat previousFrameTime;
    CFAbsoluteTime previousActualFrameTime;
    dispatch_semaphore_t frameRenderingSemaphore;
    dispatch_queue_t serialProcessingQueue;
    BOOL keepLooping;
    CGSize pixelSizeOfImage;
    int imageBufferWidth, imageBufferHeight;
    NSUInteger _frameCount;
    NSUInteger _loopCount;
    NSUInteger _loopIndex;
    NSUInteger _progressIndex;
}

@end

@implementation GPUImageGIF

@synthesize url = _url;
@synthesize playAtActualSpeed = _playAtActualSpeed;
@synthesize delegate = _delegate;
@synthesize shouldRepeat = _shouldRepeat;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithURL:(NSURL *)url;
{
    if (!(self = [super init]))
    {
        return nil;
    }
    
    serialProcessingQueue = dispatch_queue_create("com.sunsetlakesoftware.GPUImage.gifReadingQueue", GPUImageDefaultQueueAttribute());
    _loopIndex = 0;
    frameRenderingSemaphore = dispatch_semaphore_create(1);
    self.url = url;
    return self;
}

- (void)resumeProcessing {
    _loopIndex = 0;
    dispatch_semaphore_signal(self->frameRenderingSemaphore);
    [self startProcessing];
}

- (void)dealloc
{
    
    // Moved into endProcessing
    //if (self.playerItem && (displayLink != nil))
    //{
    //    [displayLink invalidate]; // remove from all run loops
    //    displayLink = nil;
    //}
}

#pragma mark -
#pragma mark Movie processing

- (void)startProcessing
{
    if (dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_NOW) != 0) {
        return;
    }
    if (self.url == nil) {
        return;
    }
    if (_shouldRepeat)
        keepLooping = YES;
    previousFrameTime = 0.0;
    previousActualFrameTime = CFAbsoluteTimeGetCurrent();
    GPUImageGIF __block *blockSelf = self;
    dispatch_async(serialProcessingQueue, ^{
        NSError *error;
        if (blockSelf.url) {
            NSData *gifData = [NSData dataWithContentsOfURL:blockSelf.url options: NSDataReadingMappedIfSafe error:&error];
            if (error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSLog(@"%@",error.localizedDescription);
                });
            }
                //Получение количества кадров для gif
            CGImageSourceRef gifReader = CGImageSourceCreateWithData((CFDataRef)gifData, NULL);
            blockSelf->_frameCount = CGImageSourceGetCount(gifReader);

                //Получение основных данных для GfiImage
            NSDictionary *gifProperties = (NSDictionary *)CFBridgingRelease(CGImageSourceCopyProperties(gifReader, NULL));
            NSDictionary *gifDictionary =[gifProperties objectForKey:(NSString*)kCGImagePropertyGIFDictionary];
            blockSelf->_loopCount = [[gifDictionary objectForKey:(NSString*)kCGImagePropertyGIFLoopCount] integerValue];
            blockSelf->_progressIndex = 0;

            for (NSUInteger i = 0; i < blockSelf->_frameCount; i++) {
                    //Получить CGImage для каждого кадра
                CGImageRef img = CGImageSourceCreateImageAtIndex(gifReader, (size_t) i, NULL);
                if (img)
                    {
                        //Получение информации gif из информации изображения каждого кадра
                    NSDictionary *frameProperties = (NSDictionary *)CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(gifReader, (size_t) i, NULL));
                    NSDictionary *frameDictionary = [frameProperties objectForKey:(NSString*)kCGImagePropertyGIFDictionary];
                        //Удалить каждый кадр delaytime
                    CGFloat delayTime = [[frameDictionary objectForKey:(NSString*)kCGImagePropertyGIFDelayTime] floatValue];

                    CGFloat currentSampleTime = blockSelf->previousFrameTime + delayTime;
                        //NSLog(@"read a video frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, CMSampleBufferGetOutputPresentationTimeStamp(sampleBufferRef))));
                    if (self->_playAtActualSpeed)
                        {
                            // Do this outside of the video processing queue to not slow that down while waiting

                        CGFloat differenceFromLastFrame = currentSampleTime - blockSelf->previousFrameTime;
                        CFAbsoluteTime currentActualTime = CFAbsoluteTimeGetCurrent();

                        CGFloat frameTimeDifference = differenceFromLastFrame;
                        CGFloat actualTimeDifference = currentActualTime - blockSelf->previousActualFrameTime;

                        if (frameTimeDifference > actualTimeDifference)
                            {
                            usleep(1000000.0 * (frameTimeDifference - actualTimeDifference));
                            }
                        blockSelf->previousActualFrameTime = CFAbsoluteTimeGetCurrent();
                        }

                    blockSelf->previousFrameTime = currentSampleTime;

                    runSynchronouslyOnVideoProcessingQueue(^{
                        [blockSelf processMovieFrame:img currentSampleTime:currentSampleTime];

                        CGSize imageSize = CGSizeMake(CGImageGetWidth(img), CGImageGetHeight(img));
                        for (id<GPUImageInput> currentTarget in blockSelf->targets)
                            {
                            NSInteger indexOfObject = [blockSelf->targets indexOfObject:currentTarget];
                            NSInteger textureIndexOfTarget = [[blockSelf->targetTextureIndices objectAtIndex:indexOfObject] integerValue];

                            [currentTarget setCurrentlyReceivingMonochromeInput:NO];
                            [currentTarget setInputSize:imageSize atIndex:textureIndexOfTarget];
                            [currentTarget setInputFramebuffer:self->outputFramebuffer atIndex:textureIndexOfTarget];
                            [currentTarget newFrameReadyAtTime:CMTimeMakeWithSeconds(currentSampleTime, 30)
                                                       atIndex:textureIndexOfTarget];
                            }
                        [blockSelf->outputFramebuffer unlock];
                        blockSelf->outputFramebuffer = nil;
                        CGImageRelease(img);
                    });
                    }

                blockSelf->_progressIndex++;
            }

            blockSelf->_loopIndex++;
            CFRelease(gifReader);

            dispatch_semaphore_signal(self->frameRenderingSemaphore);

            if ((blockSelf->keepLooping && blockSelf->_loopCount == 0) ||  blockSelf->_loopCount > blockSelf->_loopIndex) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [blockSelf startProcessing];
                });
            } else {
                [blockSelf endProcessing];
            }
        }
    });
}

- (void)processMovieFrame:(CGImageRef)movieFrame currentSampleTime:(CGFloat)currentSampleTime;
{
    // TODO: Dispatch this whole thing asynchronously to move image loading off main thread
    CGFloat widthOfImage = CGImageGetWidth(movieFrame);
    CGFloat heightOfImage = CGImageGetHeight(movieFrame);
    
    // If passed an empty image reference, CGContextDrawImage will fail in future versions of the SDK.
    NSAssert( widthOfImage > 0 && heightOfImage > 0, @"Passed image must not be empty - it should be at least 1px tall and wide");
    
    pixelSizeOfImage = CGSizeMake(widthOfImage, heightOfImage);
    CGSize pixelSizeToUseForTexture = pixelSizeOfImage;
    
    BOOL shouldRedrawUsingCoreGraphics = NO;
    
    // For now, deal with images larger than the maximum texture size by resizing to be within that limit
    CGSize scaledImageSizeToFitOnGPU = [GPUImageContext sizeThatFitsWithinATextureForSize:pixelSizeOfImage];
    if (!CGSizeEqualToSize(scaledImageSizeToFitOnGPU, pixelSizeOfImage))
    {
        pixelSizeOfImage = scaledImageSizeToFitOnGPU;
        pixelSizeToUseForTexture = pixelSizeOfImage;
        shouldRedrawUsingCoreGraphics = YES;
    }
    
    if (self.shouldSmoothlyScaleOutput)
    {
        // In order to use mipmaps, you need to provide power-of-two textures, so convert to the next largest power of two and stretch to fill
        CGFloat powerClosestToWidth = ceil(log2(pixelSizeOfImage.width));
        CGFloat powerClosestToHeight = ceil(log2(pixelSizeOfImage.height));
        
        pixelSizeToUseForTexture = CGSizeMake(pow(2.0, powerClosestToWidth), pow(2.0, powerClosestToHeight));
        
        shouldRedrawUsingCoreGraphics = YES;
    }
    
    GLubyte *imageData = NULL;
    CFDataRef dataFromImageDataProvider = NULL;
    GLenum format = GL_BGRA;
//    BOOL isLitteEndian = YES;
//    BOOL alphaFirst = NO;
//    BOOL premultiplied = NO;
    
    if (!shouldRedrawUsingCoreGraphics) {
        /* Check that the memory layout is compatible with GL, as we cannot use glPixelStore to
         * tell GL about the memory layout with GLES.
         */
        if (CGImageGetBytesPerRow(movieFrame) != CGImageGetWidth((movieFrame)) * 4 ||
            CGImageGetBitsPerPixel((movieFrame)) != 32 ||
            CGImageGetBitsPerComponent((movieFrame)) != 8)
        {
            shouldRedrawUsingCoreGraphics = YES;
        } else {
            /* Check that the bitmap pixel format is compatible with GL */
            CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(movieFrame);
            if ((bitmapInfo & kCGBitmapFloatComponents) != 0) {
                /* We don't support float components for use directly in GL */
                shouldRedrawUsingCoreGraphics = YES;
            } else {
                CGBitmapInfo byteOrderInfo = bitmapInfo & kCGBitmapByteOrderMask;
                if (byteOrderInfo == kCGBitmapByteOrder32Little) {
                    /* Little endian, for alpha-first we can use this bitmap directly in GL */
                    CGImageAlphaInfo alphaInfo = bitmapInfo & kCGBitmapAlphaInfoMask;
                    if (alphaInfo != kCGImageAlphaPremultipliedFirst && alphaInfo != kCGImageAlphaFirst &&
                        alphaInfo != kCGImageAlphaNoneSkipFirst) {
                        shouldRedrawUsingCoreGraphics = YES;
                    }
                } else if (byteOrderInfo == kCGBitmapByteOrderDefault || byteOrderInfo == kCGBitmapByteOrder32Big) {
//                    isLitteEndian = NO;
                    /* Big endian, for alpha-last we can use this bitmap directly in GL */
                    CGImageAlphaInfo alphaInfo = bitmapInfo & kCGBitmapAlphaInfoMask;
                    if (alphaInfo != kCGImageAlphaPremultipliedLast && alphaInfo != kCGImageAlphaLast &&
                        alphaInfo != kCGImageAlphaNoneSkipLast) {
                        shouldRedrawUsingCoreGraphics = YES;
                    } else {
                        /* Can access directly using GL_RGBA pixel format */
//                        premultiplied = alphaInfo == kCGImageAlphaPremultipliedLast || alphaInfo == kCGImageAlphaPremultipliedLast;
//                        alphaFirst = alphaInfo == kCGImageAlphaFirst || alphaInfo == kCGImageAlphaPremultipliedFirst;
                        format = GL_RGBA;
                    }
                }
            }
        }
    }
    
    //    CFAbsoluteTime elapsedTime, startTime = CFAbsoluteTimeGetCurrent();
    
    if (shouldRedrawUsingCoreGraphics)
    {
        // For resized or incompatible image: redraw
        imageData = (GLubyte *) calloc(1, (int)pixelSizeToUseForTexture.width * (int)pixelSizeToUseForTexture.height * 4);
        
        CGColorSpaceRef genericRGBColorspace = CGColorSpaceCreateDeviceRGB();
        
        CGContextRef imageContext = CGBitmapContextCreate(imageData, (size_t)pixelSizeToUseForTexture.width, (size_t)pixelSizeToUseForTexture.height, 8, (size_t)pixelSizeToUseForTexture.width * 4, genericRGBColorspace,  kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        //        CGContextSetBlendMode(imageContext, kCGBlendModeCopy); // From Technical Q&A QA1708: http://developer.apple.com/library/ios/#qa/qa1708/_index.html
        CGContextDrawImage(imageContext, CGRectMake(0.0, 0.0, pixelSizeToUseForTexture.width, pixelSizeToUseForTexture.height), movieFrame);
        CGContextRelease(imageContext);
        CGColorSpaceRelease(genericRGBColorspace);
    }
    else
    {
        // Access the raw image bytes directly
        dataFromImageDataProvider = CGDataProviderCopyData(CGImageGetDataProvider(movieFrame));
        imageData = (GLubyte *)CFDataGetBytePtr(dataFromImageDataProvider);
    }
    
    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext useImageProcessingContext];
        
        self->outputFramebuffer = [[GPUImageContext sharedFramebufferCache] fetchFramebufferForSize:pixelSizeToUseForTexture onlyTexture:YES];
        
        glBindTexture(GL_TEXTURE_2D, [self->outputFramebuffer texture]);
        if (self.shouldSmoothlyScaleOutput)
        {
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
        }
        // no need to use self.outputTextureOptions here since pictures need this texture formats and type
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (int)pixelSizeToUseForTexture.width, (int)pixelSizeToUseForTexture.height, 0, format, GL_UNSIGNED_BYTE, imageData);
        
        if (self.shouldSmoothlyScaleOutput)
        {
            glGenerateMipmap(GL_TEXTURE_2D);
        }
        glBindTexture(GL_TEXTURE_2D, 0);
    });
    
    if (shouldRedrawUsingCoreGraphics)
    {
        free(imageData);
    }
    else
    {
        if (dataFromImageDataProvider)
        {
            CFRelease(dataFromImageDataProvider);
        }
    }
}

- (float)progress
{
    if (_progressIndex < _frameCount)
    {
        return _progressIndex / (float)_frameCount;
    }
    else
    {
        return 1.f;
    }
}

- (void)endProcessing;
{
    keepLooping = NO;
    _loopIndex = 0;
    
    runSynchronouslyOnVideoProcessingQueue(^{
        for (id<GPUImageInput> currentTarget in self->targets)
        {
            [currentTarget endProcessing];
        }
    });
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(didCompletePlayingGIF)]) {
            [self.delegate didCompletePlayingGIF];
        }
        self.delegate = nil;
    });
//    dispatch_semaphore_signal(self->frameRenderingSemaphore);
}

- (void)cancelProcessing
{
    [self endProcessing];
//    dispatch_semaphore_signal(self->frameRenderingSemaphore);
}

- (CGSize)outputImageSize;
{
    return pixelSizeOfImage;
}
@end

