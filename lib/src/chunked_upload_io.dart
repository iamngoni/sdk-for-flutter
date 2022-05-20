import 'client.dart';
import 'dart:io' as io;
import 'enums.dart';
import 'package:http/http.dart' as http;
import 'response.dart';
import 'dart:math';
import 'input_file.dart';
import 'exception.dart';
import 'upload_progress.dart';

Future<Response> chunkedUpload({
  required Client client,
  required String path,
  required Map<String, dynamic> params,
  required String paramName,
  required String idParamName,
  required Map<String, String> headers,
  Function(UploadProgress)? onProgress,
}) async {
  InputFile file = params[paramName];
  if (file.path == null && file.bytes == null) {
    throw AppwriteException("File path or bytes must be provided");
  }

  int size = 0;
  if (file.bytes != null) {
    size = file.bytes!.length;
  }

  io.File? iofile;

  if (file.path != null) {
    iofile = io.File(file.path!);
    size = await iofile.length();
  }

  late Response res;
  if (size <= Client.CHUNK_SIZE) {
    if (file.path != null) {
      params[paramName] = await http.MultipartFile.fromPath(
          paramName, file.path!,
          filename: file.filename);
    } else {
      params[paramName] = http.MultipartFile.fromBytes(paramName, file.bytes!,
          filename: file.filename);
    }
    return client.call(
      HttpMethod.post,
      path: path,
      params: params,
      headers: headers,
    );
  }

  var offset = 0;
  if (idParamName.isNotEmpty && params[idParamName] != 'unique()') {
    //make a request to check if a file already exists
    try {
      res = await client.call(
        HttpMethod.get,
        path: path + '/' + params[idParamName],
        headers: headers,
      );
      final int chunksUploaded = res.data['chunksUploaded'] as int;
      offset = min(size, chunksUploaded * Client.CHUNK_SIZE);
    } on AppwriteException catch (_) {}
  }

  io.RandomAccessFile? raf;
  // read chunk and upload each chunk
  if (iofile != null) {
    raf = await iofile.open(mode: io.FileMode.read);
  }

  while (offset < size) {
    var chunk;
    if (file.bytes != null) {
      chunk = file.bytes!.getRange(offset, offset + Client.CHUNK_SIZE - 1);
    } else {
      raf!.setPositionSync(offset);
      chunk = raf.readSync(Client.CHUNK_SIZE);
    }
    params[paramName] =
        http.MultipartFile.fromBytes(paramName, chunk, filename: file.filename);
    headers['content-range'] =
        'bytes $offset-${min<int>(((offset + Client.CHUNK_SIZE) - 1), size)}/$size';
    res = await client.call(HttpMethod.post,
        path: path, headers: headers, params: params);
    offset += Client.CHUNK_SIZE;
    if (offset < size) {
      headers['x-{{spec.title | caseLower }}-id'] = res.data['\$id'];
    }
    final progress = UploadProgress(
      $id: res.data['\$id'] ?? '',
      progress: min(offset - 1, size) / size * 100,
      sizeUploaded: min(offset - 1, size),
      chunksTotal: res.data['chunksTotal'] ?? 0,
      chunksUploaded: res.data['chunksUploaded'] ?? 0,
    );
    onProgress?.call(progress);
  }
  raf?.close();
  return res;
}
