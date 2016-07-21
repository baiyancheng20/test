#include "outer/pvanet.h"
#include <string.h>
#include <opencv2/core/core.hpp>
#include <opencv2/highgui/highgui.hpp>
#include <opencv2/imgproc/imgproc.hpp>
#include <vector>

#include <time.h>

#ifdef _MSC_VER
  #define TEST
#endif

static
const char* gs_class_names[] = {
  "__unknown__",
  "bicycle",
  "bird",
  "bus",
  "car",
  "cat",
  "dog",
  "horse",
  "motorbike",
  "person",
  "train",
  "aeroplane",
  "boat",
  "bottle",
  "chair",
  "cow",
  "diningtable",
  "pottedplant",
  "sheep",
  "sofa",
  "tvmonitor",
  "cake_choco",
  "cake_purple",
  "cake_white",
  "sportsbag"
};

static
void draw_boxes(cv::Mat* const image,
                const real out_data[],
                const int num_boxes,
                const float time)
{
  char label[128];
  for (int r = 0; r < num_boxes; ++r) {
    const real* const p_box = out_data + r * 6;
    const char* const class_name = gs_class_names[(int)p_box[0]];
    const real score = p_box[5];
    const int x1 = (int)ROUND(p_box[1]);
    const int y1 = (int)ROUND(p_box[2]);
    const int x2 = (int)ROUND(p_box[3]);
    const int y2 = (int)ROUND(p_box[4]);
    const int w = x2 - x1 + 1;
    const int h = y2 - y1 + 1;

    if (score < 0.7) {
      continue;
    }
    sprintf(label, "%s(%.2f)", class_name, score);

    if (score >= 0.8) {
      cv::rectangle(*image, cv::Rect(x1, y1, w, h),
                    cv::Scalar(0, 0, 255), 2);
    }
    else {
      cv::rectangle(*image, cv::Rect(x1, y1, w, h),
                    cv::Scalar(255, 0, 0), 1);
    }
    cv::putText(*image, label, cv::Point(x1, y1 + 15),
            2, 0.5, cv::Scalar(0, 0, 0), 2);
    cv::putText(*image, label, cv::Point(x1, y1 + 15),
            2, 0.5, cv::Scalar(255, 255, 255), 1);
  }
  if (time > 0) {
    sprintf(label, "%.3f sec", time);
    cv::putText(*image, label, cv::Point(10, 10),
                2, 0.5, cv::Scalar(0, 0, 0), 2);
    cv::putText(*image, label, cv::Point(10, 10),
                2, 0.5, cv::Scalar(255, 255, 255), 1);
  }
}

static
void detect_frame(Net* const net,
                  cv::Mat* const image)
{
  if (image && image->data) {
    const clock_t tick0 = clock();
    real time = 0;

    real* boxes;
    int num_boxes;

    process_pvanet(net, image->data, image->rows, image->cols,
                   &boxes, &num_boxes, NULL);

    {
      clock_t tick1 = clock();
      if (time == 0) {
        time = (real)(tick1 - tick0) / CLOCKS_PER_SEC;
      }
      else {
        time = time * 0.9f + (real)(tick1 - tick0) / CLOCKS_PER_SEC * 0.1f;
      }
    }

    draw_boxes(image, boxes, num_boxes, time);

    cv::imshow("faster-rcnn", *image);
  }
}

static
void test_stream(Net* const net, cv::VideoCapture& vc)
{
  cv::Mat image;

  while (1) {
    vc >> image;
    if (image.empty()) break;

    detect_frame(net, &image);

    if (cv::waitKey(1) == 27) break; //ESC
  }
}

static
void test_image(Net* const net, const char* const filename)
{
  cv::Mat image = cv::imread(filename);
  if (!image.data) {
    printf("Cannot open image: %s\n", filename);
    return;
  }

  detect_frame(net, &image);

  cv::waitKey(0);
}

static
void test_database(Net* const net,
                   const char* const db_filename,
                   const char* const out_filename)
{
  std::vector<cv::Mat> images;
  unsigned char* p_images[BATCH_SIZE];
  int image_heights[BATCH_SIZE];
  int image_widths[BATCH_SIZE];

  real* output_boxes;
  int num_output_boxes[BATCH_SIZE];

  char buf[10240];
  char* line[20];
  int total_count = 0, count = 0, buf_count = 0;
  FILE* fp_list = fopen(db_filename, "r");

  FILE* fp_out = fopen(out_filename, "wb");

  clock_t tick0, tick1;
  float a_time[2] = { 0, };

  if (!fp_list) {
    printf("File not found: %s\n", db_filename);
  }
  if (!fp_out) {
    printf("File write error: %s\n", out_filename);
  }

  tick0 = clock();

  while (fgets(&buf[buf_count], 1024, fp_list))
  {
    {
      const int len = strlen(&buf[buf_count]);

      buf[buf_count + len - 1] = 0;
      line[count] = &buf[buf_count];
      ++count;
      buf_count += len;
    }

    if (count == BATCH_SIZE)
    {
      for (int n = 0; n < count; ++n) {
        images.push_back(cv::imread(line[n]));
      }
      for (int n = 0; n < count; ++n) {
        p_images[n] = images[n].data;
        image_heights[n] = images[n].rows;
        image_widths[n] = images[n].cols;
      }

      process_batch_pvanet(net, p_images, image_heights, image_widths,
                           count, &output_boxes, num_output_boxes, fp_out);
      images.clear();

      tick1 = clock();
      a_time[0] = (float)(tick1 - tick0) / CLOCKS_PER_SEC;
      a_time[1] += (float)(tick1 - tick0) / CLOCKS_PER_SEC;
      tick0 = tick1;
      printf("Running time: %.2f (current), %.2f (average)\n",
             a_time[0] * 1000 / count,
             a_time[1] * 1000 / (total_count + count));

      total_count += count;
      count = 0;
      buf_count = 0;
    }
  }

  if (count > 0) {
    for (int n = 0; n < count; ++n) {
      images.push_back(cv::imread(line[n]).clone());
    }
    for (int n = 0; n < count; ++n) {
      p_images[n] = images[n].data;
      image_heights[n] = images[n].rows;
      image_widths[n] = images[n].cols;
    }

    process_batch_pvanet(net, p_images, image_heights, image_widths,
                         count, &output_boxes, num_output_boxes, fp_out);
    images.clear();

    tick1 = clock();
    a_time[0] = (float)(tick1 - tick0) / CLOCKS_PER_SEC;
    a_time[1] += (float)(tick1 - tick0) / CLOCKS_PER_SEC;
    tick0 = tick1;
    printf("Running time: %.2f (current), %.2f (average)\n",
           a_time[0] * 1000 / count,
           a_time[1] * 1000 / (total_count + count));
  }

  if (fp_list) {
    fclose(fp_list);
  }
  if (fp_out) {
    fclose(fp_out);
  }
}

static
void print_usage(void)
{
  #ifdef GPU
  const char* const postfix1 = "_gpu";
  #else
  const char* const postfix1 = "_cpu";
  #endif

  #ifdef LIGHT_MODEL
  const char* const postfix2 = "_light";
  #else
  const char* const postfix2 = "";
  #endif

  #ifdef COMPRESS
  const char* const postfix3 = "_compress";
  #else
  const char* const postfix3 = "";
  #endif

  printf("[Usage] ./demo%s%s%s.bin <pre_nms_topn> <post_nms_topn> <input_size> <command> <arg1> <arg2> ...\n\n",
         postfix1, postfix2, postfix3);
  printf("  Common settings for <pre_nms_topn> <post_nms_topn> <input_size>:\n");
  printf("    pre_nms_topn = 6000 or 12000\n");
  printf("    post_nms_topn = 100, 200, or 300\n");
  printf("    input_size = 480, 576, 720, or 960\n\n");
  printf("  Settings for <command> <arg1> <arg2> ...:\n");
  printf("  1. [Live demo using WebCam] live <camera id> <width> <height>\n");
  printf("  2. [Image file] snapshot <image filename>\n");
  printf("  3. [Video file] video <video filename>\n");
  printf("  4. [List of images] database <DB filename> <output filename>\n");
}

static
int test(const char* const args[], const int num_args)
{
  Net* pvanet;
  const int pre_nms_topn = atoi(args[0]);
  const int post_nms_topn = atoi(args[1]);
  const int input_size = atoi(args[2]);
  const char* const command = args[3];

  #ifdef GPU
  cudaSetDevice(0);
  #endif

  #ifdef LIGHT_MODEL
  const int is_light_model = 1;
  const char* const model_path = "data/pvanet_light";
  #else
  const int is_light_model = 0;
  const char* const model_path = "data/pvanet";
  #endif

  #ifdef COMPRESS
  const int fc_compress = 1;
  #else
  const int fc_compress = 0;
  #endif

  if (strcmp(command, "live") == 0) {
    if (num_args >= 7) {
      const int camera_id = atoi(args[4]);
      const int frame_width = atoi(args[5]);
      const int frame_height = atoi(args[6]);

      cv::imshow("faster-rcnn", 0);
      cv::VideoCapture vc(camera_id);
      if (!vc.isOpened()) {
        printf("Cannot open camera(%d)\n", camera_id);
        cv::destroyAllWindows();
        return -1;
      }
      vc.set(CV_CAP_PROP_FRAME_WIDTH, frame_width);
      vc.set(CV_CAP_PROP_FRAME_HEIGHT, frame_height);

      pvanet = create_pvanet(model_path, is_light_model, fc_compress,
                             pre_nms_topn, post_nms_topn, input_size);
      test_stream(pvanet, vc);
      free_net(pvanet);

      cv::destroyAllWindows();
    }
    else {
      print_usage();
      return -1;
    }
  }

  else if (strcmp(command, "snapshot") == 0) {
    if (num_args >= 5) {
      const char* const filename = args[4];
      cv::imshow("faster-rcnn", 0);

      pvanet = create_pvanet(model_path, is_light_model, fc_compress,
                             pre_nms_topn, post_nms_topn, input_size);
      test_image(pvanet, filename);
      free_net(pvanet);

      cv::destroyAllWindows();
    }
    else {
      print_usage();
      return -1;
    }
  }

  else if (strcmp(command, "video") == 0) {
    if (num_args >= 5) {
      const char* const filename = args[4];

      cv::imshow("faster-rcnn", 0);
      cv::VideoCapture vc(filename);
      if (!vc.isOpened()) {
        printf("Cannot open video: %s\n", filename);
        cv::destroyAllWindows();
        return -1;
      }

      pvanet = create_pvanet(model_path, is_light_model, fc_compress,
                             pre_nms_topn, post_nms_topn, input_size);
      test_stream(pvanet, vc);
      free_net(pvanet);

      cv::destroyAllWindows();
    }
    else {
      print_usage();
      return -1;
    }
  }

  else if (strcmp(command, "database") == 0) {
    if (num_args >= 6) {
      const char* const db_filename = args[4];
      const char* const out_filename = args[5];

      pvanet = create_pvanet(model_path, is_light_model, fc_compress,
                             pre_nms_topn, post_nms_topn, input_size);
      test_database(pvanet, db_filename, out_filename);
      free_net(pvanet);
    }
    else {
      print_usage();
      return -1;
    }
  }

  else {
    print_usage();
    return -1;
  }

  return 0;
}

#ifdef TEST
int main(int argc, char* argv[])
{
  if (argc >= 6) {
    test(argv + 1, argc - 1);
  }
  else {
    print_usage();
  }

  return 0;
}
#endif
