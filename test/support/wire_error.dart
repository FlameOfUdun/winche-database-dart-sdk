/// The `error` object of an error frame, from a status as the 7.x protocol named it (`NOT_FOUND`, `INVALID_QUERY`, …).
Map<String, Object?> wireError(String status, String message, [Map<String, Object?>? details]) => {
      'code': status == 'INVALID_QUERY' ? 'invalid-argument' : status.toLowerCase().replaceAll('_', '-'),
      if (status == 'INVALID_QUERY') 'reason': 'invalid-query',
      'message': message,
      if (details != null) 'details': details,
    };
